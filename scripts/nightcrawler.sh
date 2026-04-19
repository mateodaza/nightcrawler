#!/usr/bin/env bash
# nightcrawler.sh — Deterministic bash orchestrator for autonomous task execution.
#
# Usage: nightcrawler.sh <project> [--budget N] [--codex-cap N] [--dry-run]
#        --budget N     Max Claude prompts (0 = unlimited, run until done)
#        --codex-cap N  Max Codex spend in USD (default $10)
#
# LLMs are only called for creative work (planning, coding, reviewing).
# All routing, sequencing, and error handling is deterministic bash.

set -euo pipefail

# =============================================================================
# SEC 1: Environment + constants
# =============================================================================

PROJECT="${1:?Usage: nightcrawler.sh <project> [--budget N] [--dry-run]}"
shift

# Ensure tool paths are available (nohup/systemd don't source shell profiles)
NVM_BIN=$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1)
for p in "$HOME/.foundry/bin" "$HOME/.cargo/bin" "/usr/local/bin" "$HOME/.local/bin" "$NVM_BIN"; do
    [[ -d "$p" ]] && PATH="$p:$PATH"
done
export PATH

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS/_resolve-path.sh"
STATE_DIR="${NIGHTCRAWLER_STATE_PATH:-$HOME/.nightcrawler}"
PROJECT_PATH="$(_resolve_project_path "$PROJECT")"
CONTROL_DIR="/tmp/nightcrawler/${PROJECT}"
SESSION_ID="$(date -u +%Y%m%d-%H%M%S)-${PROJECT}"
SESSION_DIR="$STATE_DIR/sessions/$SESSION_ID"
mkdir -p "$SESSION_DIR"
LOCKFILE="/tmp/nightcrawler-${PROJECT}.lock"
TOUCHED_FILES="$CONTROL_DIR/touched_files"

PROMPT_CAP=50                   # Max Claude prompts per session (default for Max 5x tier)
CODEX_DOLLAR_CAP=10.00          # Real dollar cap for Codex calls only
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --budget)
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "--budget requires a non-negative integer, got: $2" >&2; exit 1
            fi
            PROMPT_CAP="$2"; shift 2 ;;
        --codex-cap) CODEX_DOLLAR_CAP="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Project-configurable settings (defaults — overridden by .nightcrawler/config.sh)
PROJECT_DESC="software"         # e.g. "Solidity/Foundry", "Next.js/TypeScript"
BUILD_CMD="make build"
TEST_CMD="make test"
INSTALL_CMD="make install"
BUILD_WALL=120 BUILD_IDLE=60
TEST_WALL=300  TEST_IDLE=120
MAX_PLAN_ITERATIONS=10          # plan audit soft-reject cap (hard blocks + convergence catch real problems)
MAX_IMPL_ITERATIONS=10          # impl review soft-reject cap (hard blocks + convergence catch real problems)
# A4: cap per-call turns so the CLI exits naturally before the wall-clock
# safety net fires. Defaults picked as ~2x observed successful-session
# averages (see PLAN-stabilization.md A4). Override via env or project
# config. Set to "" to restore pre-A4 unlimited behavior.
PLAN_MAX_TURNS="${PLAN_MAX_TURNS:-15}"
IMPL_MAX_TURNS="${IMPL_MAX_TURNS:-40}"
REPAIR_MAX_TURNS="${REPAIR_MAX_TURNS:-}"  # empty = omit --max-turns (unlimited)
VERIFY_INSTRUCTIONS="Run '$BUILD_CMD' and '$TEST_CMD' to verify before finishing."

# Load project config if it exists (can override BUILD_CMD, TEST_CMD, etc.)
PROJECT_CONFIG="$PROJECT_PATH/.nightcrawler/config.sh"
if [[ -f "$PROJECT_CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$PROJECT_CONFIG"
    # Refresh verify instructions after config override
    VERIFY_INSTRUCTIONS="Run '$BUILD_CMD' and '$TEST_CMD' to verify before finishing."
fi

# Timeouts (seconds)
PLAN_WALL=300   PLAN_IDLE=120
AUDIT_WALL=180  AUDIT_IDLE=60
IMPL_WALL=600   IMPL_IDLE=180
REVIEW_WALL=180 REVIEW_IDLE=60
CODEX_CALL_TIMEOUT=180  # wall-clock safety net for Codex (has internal timeouts)
CLAUDE_CLI_TIMEOUT=3600 # wall-clock safety net for Claude Code CLI (60min — Opus planning can be slow)

# -----------------------------------------------------------------------------
# Streamed-path timeouts (Phase A, A1+A2). Used only when NC_USE_STREAM=1.
# Wall caps are per-stage so a stuck implement doesn't consume the plan budget.
# Idle caps are opt-in (default 0 = disabled) while we verify heartbeat behavior.
# See PLAN-stabilization.md Phase A for rationale.
PLAN_WALL_TIMEOUT="${PLAN_WALL_TIMEOUT:-1200}"      # 20min — per plan turn
IMPL_WALL_TIMEOUT="${IMPL_WALL_TIMEOUT:-2400}"      # 40min — per implement/revise turn
REVIEW_WALL_TIMEOUT="${REVIEW_WALL_TIMEOUT:-600}"   # 10min — reserved for future use
PLAN_IDLE_TIMEOUT="${PLAN_IDLE_TIMEOUT:-0}"         # 0 = disabled
IMPL_IDLE_TIMEOUT="${IMPL_IDLE_TIMEOUT:-0}"         # 0 = disabled
REVIEW_IDLE_TIMEOUT="${REVIEW_IDLE_TIMEOUT:-0}"     # 0 = disabled

# Dark-launch gate: set NC_USE_STREAM=1 to route plan/implement/revise through
# the stream-accumulator. Default 0 preserves the legacy `claude ... --output-format json`
# path byte-for-byte so nightly runs are unaffected until we flip this on.
NC_USE_STREAM="${NC_USE_STREAM:-0}"

# Strip API keys from environment — force both CLIs to use subscription auth.
# Claude CLI uses `claude login` session; Codex CLI uses ~/.codex/config.json.
unset ANTHROPIC_API_KEY 2>/dev/null || true
unset OPENAI_API_KEY 2>/dev/null || true

# Claude Code auto-compaction control.
# Each `claude -p` call is a fresh session, but within a 20-25 turn call,
# reading many source files can fill context and trigger auto-compaction.
# Compaction summarizes away the original prompt (plan, task details, rules).
# Setting threshold to 95% delays compaction, preserving more context.
# Critical instructions survive via .claude/CLAUDE.md (reloaded after compaction).
export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=95

# Load credentials from ~/.env (systemd doesn't inherit shell env vars).
# OPENAI_API_KEY stored in _OPENAI_KEY (not exported) — passed only to Codex API fallback.
_OPENAI_KEY=""
if [[ -f "$HOME/.env" ]]; then
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        value="${value%\"}" ; value="${value#\"}"  # strip quotes
        case "$key" in
            TELEGRAM_BOT_TOKEN|TELEGRAM_CHAT_ID)
                export "$key=$value"
                ;;
            OPENAI_API_KEY)
                _OPENAI_KEY="$value"
                ;;
        esac
    done < "$HOME/.env"
fi

# =============================================================================
# SEC 2: State flags
# =============================================================================

SESSION_INITIALIZED=false
SESSION_ENDING=false
ORDERLY_EXIT=false
HEARTBEAT_STARTED=false
RECOVERY_NEEDED=false
RECOVERY_LAST_EVENT=""
RECOVERY_TASK_ID=""
RECOVERY_COMMIT=""
RECOVERY_SESSION_ID=""
TASK_COST=0
TOTAL_COST=0
PROMPT_COUNT=0              # Claude CLI prompts used this session (the real limit on Max)
CODEX_COST=0                # Real dollars spent on Codex only
CODEX_DEGRADED=false        # true = Codex unavailable, skip audit/review with synthetic APPROVED
THROTTLE_WARNED=false       # true = already warned about approaching prompt limit

# =============================================================================
# SEC 3: Helpers
# =============================================================================

log() { local msg="[$(date -u +%FT%TZ)] $*"; echo "$msg" >> "$SESSION_DIR/nightcrawler.log" 2>/dev/null; echo "$msg" >&2; }

# Pipe prompt via stdin to avoid ARG_MAX, with built-in timeout.
# Usage: call_claude <timeout_secs> "$prompt" --model sonnet --output-format json ...
call_claude() {
    local tmo="$1"; shift
    local prompt="$1"; shift
    local tmpf="/tmp/nightcrawler-prompt.$$.$(date +%s%N)"
    printf '%s' "$prompt" > "$tmpf"
    timeout "$tmo" claude -p "$@" < "$tmpf"
    local rc=$?
    rm -f "$tmpf"
    return $rc
}

run_timed() {
    local wall="$1" idle="$2"; shift 2
    python3 "$SCRIPTS/run_with_timeout.py" "$wall" "$idle" bash -c "$*"
}

# -----------------------------------------------------------------------------
# call_claude_streamed — Phase A (A1, A2, A3).
#
# Runs `claude -p --output-format stream-json --verbose` piped through
# scripts/lib/stream-accumulator.py, wrapped in run_with_timeout.py for
# wall + idle safety. stderr is split INSIDE the pipeline to per-stream
# log files so neither claude's warnings nor the accumulator's diagnostics
# can corrupt the JSON envelope on stdout.
#
# Usage:
#   call_claude_streamed <wall> <idle> <envelope_out> <cli_stderr> <acc_stderr> <prompt> [claude_args...]
#
# Emits the final envelope JSON on stdout so existing callers can keep
# using `raw_output=$(call_claude_streamed ...)`. When the pipeline is
# killed by timeout/SIGKILL, the envelope-out file on disk holds the
# latest partial snapshot (atomically written by the accumulator) and
# this function cats that file to stdout so the caller always gets a
# parseable JSON — natural or partial.
#
# Exit codes:
#   0   natural completion (accumulator saw a result event)
#   2   partial envelope (stream ended before result event)
#   124 wall timeout (run_with_timeout.py)
#   125 idle timeout (run_with_timeout.py)
#   other — claude CLI or accumulator failure
#
# Idle ≤0 disables the idle check (clamps to wall). Opt into idle by
# setting PLAN_IDLE_TIMEOUT / IMPL_IDLE_TIMEOUT / REVIEW_IDLE_TIMEOUT > 0
# once heartbeat behavior has been verified in production.
call_claude_streamed() {
    local wall="$1" idle="$2" envelope_out="$3" cli_stderr="$4" acc_stderr="$5"
    local prompt="$6"
    shift 6

    local tmpf
    tmpf="/tmp/nightcrawler-prompt.$$.$(date +%s%N)"
    printf '%s' "$prompt" > "$tmpf"

    # Idle ≤0 means disabled — clamp to wall so idle cannot fire before wall.
    local idle_arg="$idle"
    if [[ -z "$idle_arg" ]] || [[ "$idle_arg" -le 0 ]]; then
        idle_arg="$wall"
    fi

    # Shell-quote each claude arg for the bash -c subshell.
    local claude_args_q=""
    local a
    for a in "$@"; do
        claude_args_q+=" $(printf '%q' "$a")"
    done

    mkdir -p "$(dirname "$envelope_out")" "$(dirname "$cli_stderr")" "$(dirname "$acc_stderr")"
    : > "$cli_stderr"
    : > "$acc_stderr"

    local q_prompt_file q_cli_err q_acc_err q_acc q_env
    q_prompt_file=$(printf '%q' "$tmpf")
    q_cli_err=$(printf '%q' "$cli_stderr")
    q_acc_err=$(printf '%q' "$acc_stderr")
    q_acc=$(printf '%q' "$SCRIPTS/lib/stream-accumulator.py")
    q_env=$(printf '%q' "$envelope_out")

    set +e
    # Pipeline runs under run_with_timeout.py so wall+idle apply to the
    # WHOLE group (claude + accumulator). pipefail so a claude crash
    # propagates its exit code instead of being masked by the accumulator.
    python3 "$SCRIPTS/run_with_timeout.py" "$wall" "$idle_arg" \
        bash -c "set -o pipefail; claude -p $claude_args_q --output-format stream-json --verbose < $q_prompt_file 2>>$q_cli_err | python3 $q_acc --envelope-out $q_env 2>>$q_acc_err" \
        >/dev/null
    local rc=$?
    set -e

    rm -f "$tmpf"

    # Emit the envelope for the caller. Authoritative for both natural
    # and partial exits — the accumulator writes it atomically.
    if [[ -f "$envelope_out" ]]; then
        cat "$envelope_out"
    fi

    return $rc
}

journal() {
    local entry="$1"
    mkdir -p "$SESSION_DIR"
    echo "$entry" >> "$SESSION_DIR/journal.jsonl"
    python3 -c "
import os
fd = os.open('$SESSION_DIR/journal.jsonl', os.O_RDONLY)
os.fsync(fd)
os.close(fd)
" 2>/dev/null || true
}

html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    echo "$s"
}

_tg_send() {
    local msg="$1" use_thread="${2:-true}"
    local escaped
    escaped=$(html_escape "$msg")
    local -a args=(
        -d chat_id="$TELEGRAM_CHAT_ID"
        -d parse_mode=HTML
        -d text="$escaped"
    )
    if [[ "$use_thread" == "true" ]] && [[ -n "${TELEGRAM_THREAD_ID:-}" ]]; then
        args+=(-d message_thread_id="$TELEGRAM_THREAD_ID")
    fi
    local response
    response=$(curl -s --connect-timeout 5 --max-time 10 \
        -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        "${args[@]}")
    if echo "$response" | python3 -c "import sys,json; sys.exit(0 if json.load(sys.stdin).get('ok') else 1)" 2>/dev/null; then
        return 0
    fi
    # If thread send failed, retry without thread ID (falls back to General)
    if [[ "$use_thread" == "true" ]] && [[ -n "${TELEGRAM_THREAD_ID:-}" ]]; then
        _tg_send "$msg" "false"
        return $?
    fi
    return 1
}

notify_normal() {
    [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] && return 0
    [[ -z "${TELEGRAM_CHAT_ID:-}" ]] && return 0
    _tg_send "$1" || true
}

escalate_urgent() {
    [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] && return 0
    [[ -z "${TELEGRAM_CHAT_ID:-}" ]] && return 0
    local attempt
    for attempt in 1 2 3; do
        _tg_send "$1" && return 0
        sleep 5
    done
}

die() {
    log "FATAL: $*"
    escalate_urgent "FATAL ($PROJECT): $*"
    exit 1
}

budget_pre_check() {
    # Track 1: Claude prompt count (the real constraint on Max subscription)
    # PROMPT_CAP=0 means "until done" — no prompt limit, run until tasks exhausted or rate limited
    if [[ $PROMPT_CAP -gt 0 ]]; then
        if [[ $PROMPT_COUNT -ge $PROMPT_CAP ]]; then
            log "Prompt cap reached ($PROMPT_COUNT/$PROMPT_CAP)"
            return 1
        fi

        # Warn at 80% of prompt cap
        local warn_threshold=$(( PROMPT_CAP * 80 / 100 ))
        if [[ $PROMPT_COUNT -ge $warn_threshold ]] && [[ "$THROTTLE_WARNED" != "true" ]]; then
            THROTTLE_WARNED=true
            local remaining=$(( PROMPT_CAP - PROMPT_COUNT ))
            notify_normal "⚠️ Prompt budget: ${PROMPT_COUNT}/${PROMPT_CAP} used. ~${remaining} remaining."
            log "THROTTLE: 80% prompt cap warning ($PROMPT_COUNT/$PROMPT_CAP)"
        fi
    fi

    # Track 2: Codex real dollar cap
    local codex_over
    codex_over=$(python3 -c "print('yes' if $CODEX_COST >= $CODEX_DOLLAR_CAP else 'no')" 2>/dev/null || echo "no")
    if [[ "$codex_over" == "yes" ]]; then
        log "Codex dollar cap reached (\$$CODEX_COST/\$$CODEX_DOLLAR_CAP)"
        CODEX_DEGRADED=true
        notify_normal "⚠️ Codex budget exhausted (\$$CODEX_COST) — continuing without auditor"
    fi

    return 0
}

# Increment prompt counter after each Claude CLI call.
count_prompt() {
    PROMPT_COUNT=$((PROMPT_COUNT + 1))
    if [[ $PROMPT_CAP -gt 0 ]]; then
        log "PROMPT: #${PROMPT_COUNT}/${PROMPT_CAP}"
    else
        log "PROMPT: #${PROMPT_COUNT} (unlimited mode)"
    fi
}

log_claude_cli_cost() {
    local raw_output="$1" task_id="$2" phase="$3"

    # Count the prompt (this is what actually matters on Max subscription)
    count_prompt

    # Extract cost/tokens — Sonnet is free on Max but API-equivalent USD is a
    # useful reference metric for understanding how much work was done.
    local cost_info
    cost_info=$(echo "$raw_output" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    cost = data.get('total_cost_usd', data.get('cost_usd', data.get('cost', 0)))
    usage = data.get('usage', {})
    inp = usage.get('input_tokens', 0) \
        + usage.get('cache_creation_input_tokens', 0) \
        + usage.get('cache_read_input_tokens', 0)
    out = usage.get('output_tokens', 0)
    model = list(data.get('modelUsage', {}).keys())[0] if data.get('modelUsage') else data.get('model', 'unknown')
    print(json.dumps({'cost_usd': cost, 'input_tokens': inp, 'output_tokens': out, 'model': model, 'source': 'claude'}))
except:
    print(json.dumps({'cost_usd': 0, 'input_tokens': 0, 'output_tokens': 0, 'model': 'unknown', 'source': 'claude'}))
" 2>/dev/null)

    local cost
    cost=$(echo "$cost_info" | python3 -c "import sys,json;print(json.load(sys.stdin).get('cost_usd',0))" 2>/dev/null || echo "0")

    # Accumulate API-equivalent cost as reference (not for budget enforcement)
    TASK_COST=$(python3 -c "print(round($TASK_COST + $cost, 6))" 2>/dev/null || echo "$TASK_COST")
    TOTAL_COST=$(python3 -c "print(round($TOTAL_COST + $cost, 6))" 2>/dev/null || echo "$TOTAL_COST")

    python3 "$SCRIPTS/budget.py" log "$SESSION_ID" "$cost_info" >/dev/null 2>&1 || true
}

log_codex_cost() {
    local raw_output="$1"
    local cost
    cost=$(echo "$raw_output" | python3 -c "import sys,json;print(json.load(sys.stdin).get('cost_usd',0))" 2>/dev/null || echo "0")
    if [[ "$cost" != "0" ]]; then
        # Codex costs real money — track it
        CODEX_COST=$(python3 -c "print(round($CODEX_COST + $cost, 6))" 2>/dev/null || echo "$CODEX_COST")
        TASK_COST=$(python3 -c "print(round($TASK_COST + $cost, 6))" 2>/dev/null || echo "$TASK_COST")
        TOTAL_COST=$(python3 -c "print(round($TOTAL_COST + $cost, 6))" 2>/dev/null || echo "$TOTAL_COST")
        local cost_info
        cost_info=$(echo "$raw_output" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    data['source'] = 'codex'
    print(json.dumps(data))
except:
    print(json.dumps({'cost_usd': $cost, 'source': 'codex'}))
" 2>/dev/null)
        python3 "$SCRIPTS/budget.py" log "$SESSION_ID" "$cost_info" >/dev/null 2>&1 || true

        # Inline Codex cap enforcement — don't wait for next budget_pre_check()
        local over
        over=$(python3 -c "print('yes' if $CODEX_COST >= $CODEX_DOLLAR_CAP else 'no')" 2>/dev/null || echo "no")
        if [[ "$over" == "yes" ]] && [[ "$CODEX_DEGRADED" != "true" ]]; then
            CODEX_DEGRADED=true
            notify_normal "⚠️ Codex budget exhausted (\$$CODEX_COST) — switching to degraded mode"
            log "Codex cap hit after log_codex_cost (\$$CODEX_COST >= \$$CODEX_DOLLAR_CAP)"
        fi
    fi
}

update_status() {
    local status="$1"
    echo "$status" > "/tmp/nightcrawler-${PROJECT}-status" 2>/dev/null || true
}

start_heartbeat() {
    (
        exec 200>&-  # release inherited lock FD so heartbeat can't hold the flock
        while true; do
            echo "${SESSION_ID} $(date -u +%FT%TZ) $$" > "/tmp/nightcrawler-${PROJECT}-heartbeat"
            sleep 600
        done
    ) &
    HEARTBEAT_PID=$!
    HEARTBEAT_STARTED=true
    log "Heartbeat started (PID $HEARTBEAT_PID)"
}

stop_heartbeat() {
    if [[ "$HEARTBEAT_STARTED" == "true" ]] && [[ -n "${HEARTBEAT_PID:-}" ]]; then
        kill "$HEARTBEAT_PID" 2>/dev/null || true
        wait "$HEARTBEAT_PID" 2>/dev/null || true
        HEARTBEAT_STARTED=false
        rm -f "/tmp/nightcrawler-${PROJECT}-heartbeat"
    fi
}


# --- File ownership: content-based provenance ---

record_touched_files() {
    cd "$PROJECT_PATH"
    local snap="$CONTROL_DIR/touched_snap"
    : > "$snap"

    _snap_file() {
        local f="$1"
        [[ -z "$f" ]] && return
        if [[ -e "$f" ]]; then
            printf '%s\t%s\n' "$f" "$(git hash-object "$f" 2>/dev/null)" >> "$snap"
        else
            printf '%s\tDELETED\n' "$f" >> "$snap"
        fi
    }

    while IFS= read -r -d '' f; do _snap_file "$f"; done \
        < <(git diff --name-only -z HEAD -- 2>/dev/null)
    while IFS= read -r -d '' f; do _snap_file "$f"; done \
        < <(git diff --name-only -z --cached HEAD -- 2>/dev/null)
    while IFS= read -r -d '' f; do _snap_file "$f"; done \
        < <(git ls-files --others --exclude-standard -z)

    if [[ -s "$TOUCHED_FILES" ]]; then
        awk -F'\t' '{data[$1]=$0} END {for(k in data) print data[k]}' \
            "$TOUCHED_FILES" "$snap" | sort -t$'\t' -k1,1 > "$TOUCHED_FILES.tmp"
        mv "$TOUCHED_FILES.tmp" "$TOUCHED_FILES"
    else
        sort -t$'\t' -k1,1 -u "$snap" > "$TOUCHED_FILES"
    fi
    rm -f "$snap"
}

revert_owned_files() {
    [[ -f "$TOUCHED_FILES" ]] || return 0
    cd "$PROJECT_PATH"
    local reverted=0 skipped=0

    while IFS=$'\t' read -r f recorded_hash; do
        [[ -z "$f" ]] && continue

        if [[ "$recorded_hash" == "DELETED" ]]; then
            if [[ ! -e "$f" ]]; then
                if git cat-file -e "HEAD:$f" 2>/dev/null; then
                    git checkout HEAD -- "$f" 2>/dev/null || true
                    reverted=$((reverted + 1))
                fi
            else
                log "SKIP $f — restored since crash"
                skipped=$((skipped + 1))
            fi
            continue
        fi

        if [[ ! -e "$f" ]]; then
            skipped=$((skipped + 1))
            continue
        fi

        local current_hash
        current_hash=$(git hash-object "$f" 2>/dev/null || echo "ERR")
        if [[ "$current_hash" != "$recorded_hash" ]]; then
            log "SKIP $f — modified since crash (${recorded_hash:0:8} -> ${current_hash:0:8})"
            skipped=$((skipped + 1))
            continue
        fi

        if git cat-file -e "HEAD:$f" 2>/dev/null; then
            git checkout HEAD -- "$f" 2>/dev/null || true
        else
            git rm -f --cached -- "$f" 2>/dev/null || true
            case "$f" in ..|../*|/*|"") continue ;; esac
            rm -rf -- "$f" 2>/dev/null || true
        fi
        reverted=$((reverted + 1))
    done < "$TOUCHED_FILES"

    [[ $skipped -gt 0 ]] && log "Skipped $skipped files (modified/removed since crash)"
    log "Reverted $reverted Nightcrawler-owned files"
}

rotate_manifest() {
    if [[ -f "$TOUCHED_FILES" ]]; then
        mv "$TOUCHED_FILES" "$TOUCHED_FILES.prev-${SESSION_ID}"
        log "Archived previous manifest"
    fi
    : > "$TOUCHED_FILES"
}

# --- Pre-switch worktree safety gate ---

require_clean_worktree_for_switch() {
    local current
    current=$(git -C "$PROJECT_PATH" rev-parse --abbrev-ref HEAD)
    if [[ "$current" == "nightcrawler/dev" ]]; then
        return 0
    fi

    if [[ -z "$(git -C "$PROJECT_PATH" status --porcelain 2>/dev/null)" ]]; then
        return 0
    fi

    if [[ "$RECOVERY_NEEDED" == "true" ]]; then
        local prev_touched="$CONTROL_DIR/touched_files"
        if [[ -f "$prev_touched" ]]; then
            log "Dirty worktree on $current — cleaning Nightcrawler crash residue"
            local saved="$TOUCHED_FILES"
            TOUCHED_FILES="$prev_touched"
            revert_owned_files
            TOUCHED_FILES="$saved"

            if [[ -z "$(git -C "$PROJECT_PATH" status --porcelain 2>/dev/null)" ]]; then
                log "Crash residue cleaned on $current"
                return 0
            fi
            die "Worktree dirty on '$current' after cleaning crash residue — manual cleanup needed"
        fi
    fi

    die "Worktree dirty on '$current' — commit or stash before running Nightcrawler"
}

# --- Scope verification ---

verify_impl_scope() {
    # Scope checking disabled — trust the plan + review pipeline.
    # The ghost-commit guard in commit_and_close_task() catches empty commits.
    log "SCOPE: skipped (disabled)"
    return 0
}

# =============================================================================
# SEC 4: Task queue
# =============================================================================

pick_next_task() {
    local queue="$PROJECT_PATH/TASK_QUEUE.md"
    if [[ ! -f "$queue" ]]; then
        log "pick_next_task: TASK_QUEUE.md not found at $queue"
        echo ""
        return
    fi

    # Build context for the LLM
    local skip_file="$CONTROL_DIR/skip"
    local skip_context=""
    if [[ -f "$skip_file" ]] && [[ -s "$skip_file" ]]; then
        skip_context="
SKIP LIST (do NOT pick these — they failed earlier this session):
$(cat "$skip_file")
"
    fi

    # Recent git history — helps LLM see what's actually been done
    local git_context=""
    git_context=$(git -C "$PROJECT_PATH" log --oneline -15 2>/dev/null || echo "(no git history)")

    # Quick build/test status
    local build_status=""
    if cd "$PROJECT_PATH" && eval "$BUILD_CMD" >/dev/null 2>&1; then
        build_status="BUILD: passing"
    else
        build_status="BUILD: FAILING — consider if this blocks anything"
    fi

    local prompt
    read -r -d '' prompt <<'PROMPT_END' || true
You are a smart task scheduler for an autonomous coding agent. Your job: maximize productive work.

Read the TASK_QUEUE.md and pick the next task to execute. Be pragmatic, not bureaucratic.

STATUS MARKERS:
- [x] = completed
- [ ] = queued (eligible candidate)
- [~] = was in progress, session crashed — treat as incomplete but recoverable
- [🚧] or MANUAL = human-only, always skip
- Any other marker = skip

PICKING LOGIC (in priority order):

1. STANDARD PICK: Find the first [ ] task whose dependencies are ALL [x], not in skip list, not MANUAL. This is the normal case.

2. SMART RECOVERY: If a task is marked [~] (crashed in-progress) and its deps are [x], it's a BETTER pick than a fresh [ ] task — the work is partially done. Pick it.

3. VERIFY STATUS: Cross-check the git log. If a task is marked [ ] but the git log shows it was already implemented (commit message mentions the task ID), it might be stale. Still pick it — the orchestrator will verify and skip if truly done.

4. NEVER RETURN NONE IF WORK EXISTS: If strict dependency checking blocks everything but you can see tasks that are practically unblocked (e.g., dep is [~] but git log shows the dep's code was committed), pick the task anyway. Bias toward action.

5. TRULY NOTHING: Only say NONE if every non-manual task is either [x], in the skip list, or genuinely blocked on incomplete dependencies with no evidence of completion.

RESPOND WITH EXACTLY ONE LINE: just the task ID (e.g. CAM-004, NC-017) or NONE.
PROMPT_END

    # Append all context
    prompt="${prompt}
${skip_context}
RECENT GIT LOG:
${git_context}

${build_status}

TASK_QUEUE.md:
$(cat "$queue")"

    log "pick_next_task: asking Sonnet to pick from queue"

    # Retry up to 3x — a rate limit or transient failure here would silently end the session
    local raw_output exit_code=1
    local claude_stderr="/tmp/nightcrawler-pick-stderr.$$"
    local pick_attempt
    for pick_attempt in 1 2 3; do
        set +e
        raw_output=$(cd "$PROJECT_PATH" && \
            call_claude 60 "$prompt" \
                --model sonnet \
                --output-format json \
                --max-turns 1 2>"$claude_stderr")
        exit_code=$?
        set -e
        if [[ $exit_code -eq 0 ]]; then
            break
        fi
        log "pick_next_task: attempt $pick_attempt/3 failed (exit $exit_code). stderr: $(head -3 "$claude_stderr" 2>/dev/null)"
        if [[ $pick_attempt -lt 3 ]]; then
            # Exponential backoff — rate limits need time to clear
            local wait_secs=$((30 * pick_attempt))
            log "pick_next_task: waiting ${wait_secs}s before retry (possible rate limit)"
            sleep "$wait_secs"
        fi
    done

    if [[ $exit_code -ne 0 ]]; then
        log "pick_next_task: all 3 attempts failed — returning empty (session will end)"
        escalate_urgent "WARNING ($PROJECT): Task picker failed 3x (possible rate limit) — session ending"
        rm -f "$claude_stderr"
        echo ""
        return
    fi
    rm -f "$claude_stderr"

    # Log cost (small but track it)
    log_claude_cli_cost "$raw_output" "pick_task" "task-pick"

    # Extract .result from JSON
    local answer
    answer=$(echo "$raw_output" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('result', '').strip())
except:
    print('')
" 2>/dev/null)

    # Validate: must look like a task ID (NC-XXX) or NONE
    if [[ "$answer" == "NONE" ]] || [[ -z "$answer" ]]; then
        log "pick_next_task: no eligible task (model said: ${answer:-empty})"
        echo ""
        return
    fi

    # Strip any extra text — model should return just the ID but be safe
    local task_id
    task_id=$(echo "$answer" | grep -oE '[A-Z]+-[0-9A-Z]+' | head -1)

    if [[ -z "$task_id" ]]; then
        log "pick_next_task: could not parse task ID from model response: $answer"
        echo ""
        return
    fi

    log "pick_next_task: selected $task_id"
    echo "$task_id"
}

extract_task_context() {
    local task_id="$1"
    local queue="$PROJECT_PATH/TASK_QUEUE.md"
    python3 -c "
import re

with open('$queue') as f:
    lines = f.readlines()

# Find task header line: #### NC-XXX [ ] Title  or  #### NC-XXX [~] Title
task_id = '$task_id'
header_re = re.compile(r'^#{1,6}\s+' + re.escape(task_id) + r'\s+\[.\]')
found = False
for i, line in enumerate(lines):
    if header_re.match(line):
        print(line.rstrip())
        # Print subsequent non-header lines (the task body)
        for j in range(i+1, len(lines)):
            if re.match(r'^#{1,6}\s', lines[j]):
                break
            print(lines[j].rstrip())
        found = True
        break

if not found:
    print('Task ' + task_id)
" 2>/dev/null
}

mark_task_done_in_queue() {
    local task_id="$1"
    local queue="$PROJECT_PATH/TASK_QUEUE.md"
    # Match both [ ] (queued) and [~] (in progress)
    sed -i -E "s/${task_id} \[[ ~]\]/${task_id} [x]/" "$queue"
}

mark_task_in_progress() {
    local task_id="$1"
    local queue="$PROJECT_PATH/TASK_QUEUE.md"
    sed -i "s/${task_id} \[ \]/${task_id} [~]/" "$queue"
}

append_to_progress() {
    local task_id="$1" degraded_note="${2:-}"
    local progress="$PROJECT_PATH/PROGRESS.md"
    local hash
    hash=$(git -C "$PROJECT_PATH" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    local line="- **${task_id}** — $(date -u +%F) — \`${hash}\` — Session: ${SESSION_ID}"
    if [[ -n "$degraded_note" ]]; then
        line="${line} — ⚠ $(echo -e "$degraded_note" | head -1)"
    fi
    echo "$line" >> "$progress"
}

count_tasks() {
    local queue="$PROJECT_PATH/TASK_QUEUE.md"
    [[ -f "$queue" ]] || { echo "0"; return; }
    # Count [ ] tasks excluding MANUAL — approximate, just for notifications
    local n
    n=$(grep -cE '^\#{4}\s+[A-Z]+-[0-9]+\s+\[ \]' "$queue" 2>/dev/null) || true
    echo "${n:-0}"
}

# Session memory — learnings accumulate across tasks within a session.
# Each completed task contributes a 1-line insight that feeds into subsequent task prompts.
LEARNINGS_FILE=""  # set in startup

capture_task_learning() {
    local task_id="$1" commit_hash="$2"
    [[ -z "$LEARNINGS_FILE" ]] && return

    # Get the diff summary for this task
    local diff_stat
    diff_stat=$(git -C "$PROJECT_PATH" diff --stat "${commit_hash}^..${commit_hash}" 2>/dev/null | tail -5)

    local learning_prompt="You just completed task $task_id for project $PROJECT.

Diff summary:
$diff_stat

Write ONE line (max 120 chars) capturing the most useful technical insight for someone implementing the NEXT task in this codebase. Focus on patterns, gotchas, or conventions discovered — not what you did.

Examples of good learnings:
- API client requires auth header even for public endpoints — 403 without it
- Test fixtures must call cleanup() in afterEach or state leaks between tests
- The config loader merges defaults AFTER env vars — override order matters

RESPOND WITH EXACTLY ONE LINE. No prefix, no quotes."

    local raw_output
    raw_output=$(cd "$PROJECT_PATH" && \
        call_claude 30 "$learning_prompt" \
            --model sonnet \
            --output-format json \
            --max-turns 1 2>/dev/null) || return 0

    local learning
    learning=$(echo "$raw_output" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('result', '').strip().split('\n')[0][:150])
except:
    print('')
" 2>/dev/null)

    if [[ -n "$learning" ]]; then
        echo "- [$task_id] $learning" >> "$LEARNINGS_FILE"
        log "Learning captured: $learning"
    fi
}

get_session_learnings() {
    [[ -z "$LEARNINGS_FILE" ]] && return
    [[ -f "$LEARNINGS_FILE" ]] || return
    local content
    content=$(cat "$LEARNINGS_FILE" 2>/dev/null)
    [[ -z "$content" ]] && return
    echo "
SESSION LEARNINGS (from earlier tasks this session — use these insights):
$content
"
}

# =============================================================================
# SEC 5: Phase A — Plan
# =============================================================================

plan_task() {
    local task_file="$1" task_id="$2"
    local plan_dir="$SESSION_DIR/tasks/$task_id"
    mkdir -p "$plan_dir"
    local plan_file="$plan_dir/mini_plan.md"

    local task_content
    task_content=$(cat "$task_file")
    local rules
    rules=$(cat "$STATE_DIR/RULES.md" 2>/dev/null || echo "No rules file found")

    # Claude outputs plan as text (not file write) — we extract from JSON .result
    # This avoids sandbox issues (SESSION_DIR is outside PROJECT_PATH)
    local learnings
    learnings=$(get_session_learnings 2>/dev/null || true)

    local prompt="You are planning a task for a ${PROJECT_DESC} project.

TASK:
${task_content}
${learnings}
RULES (coding standards — reference during planning, not primary context):
${rules}

MANDATORY READS — you MUST read ALL of these before writing any plan:
1. TASK_QUEUE.md — read the FULL entry for this task including ALL acceptance criteria and sub-items.
2. .claude/CLAUDE.md — project-specific conventions, key files, and architecture notes. Follow all instructions there.
3. All existing source files — understand what's already built so you don't duplicate or conflict.
4. All existing test files — understand existing test patterns and helpers.
5. Project config files (package.json, tsconfig, foundry.toml, Cargo.toml, etc.) — understand build settings and dependencies.

DONE CRITERIA — your plan is complete when ALL of these are true:
- Every acceptance criterion from TASK_QUEUE.md maps to at least one plan item AND one test case
- Every function/component has a clear specification (name, parameters, return types, behavior)
- Test cases cover: happy path, error cases, edge cases from acceptance criteria
- Plan follows all conventions described in .claude/CLAUDE.md

UNCERTAINTY PROTOCOL:
- If a spec or reference doc is ambiguous or contradictory, flag it as [AMBIGUOUS: description] in your plan. Do NOT guess — the auditor will assess your interpretation.
- If a TASK_QUEUE.md acceptance criterion is unclear, note your interpretation with [INTERPRETED: criterion → your reading].

Instructions:
- You have limited turns. Read all files FIRST, then output the plan in ONE response. Do not explore incrementally.
- Do NOT implement the code — only plan.
- Do NOT create or modify any source files.
"

    log "Planning $task_id"
    update_status "planning $task_id"
    notify_normal "📋 Planning $task_id"

    local raw_output exit_code
    local claude_stderr="$SESSION_DIR/claude_plan_${task_id}_stderr.log"
    local acc_stderr="$SESSION_DIR/claude_plan_${task_id}_acc_stderr.log"
    local envelope_path="${LAST_CLAUDE_JSON_PATH:-$SESSION_DIR/last_claude.${task_id}.plan.json}"
    set +e
    local plan_model="${PLAN_MODEL:-sonnet}"
    log "Planning with model: $plan_model (stream=$NC_USE_STREAM)"
    if [[ "$NC_USE_STREAM" == "1" ]]; then
        raw_output=$(cd "$PROJECT_PATH" && \
            call_claude_streamed \
                "$PLAN_WALL_TIMEOUT" "$PLAN_IDLE_TIMEOUT" \
                "$envelope_path" "$claude_stderr" "$acc_stderr" \
                "$prompt" \
                --model "$plan_model" \
                ${PLAN_MAX_TURNS:+--max-turns $PLAN_MAX_TURNS})
    else
        raw_output=$(cd "$PROJECT_PATH" && \
            call_claude "$CLAUDE_CLI_TIMEOUT" "$prompt" \
                --model "$plan_model" \
                --output-format json \
                ${PLAN_MAX_TURNS:+--max-turns $PLAN_MAX_TURNS} 2>"$claude_stderr")
    fi
    exit_code=$?
    set -e

    log_claude_cli_cost "$raw_output" "$task_id" "planning"

    if [[ $exit_code -ne 0 ]]; then
        # Stream-only exit codes (125 idle, 2 partial) gated behind the flag.
        if [[ "$NC_USE_STREAM" == "1" ]]; then
            case $exit_code in
                124) log "Plan wall-timed-out (${PLAN_WALL_TIMEOUT}s). stderr: $(head -5 "$claude_stderr" 2>/dev/null)" ;;
                125) log "Plan idle-timed-out (${PLAN_IDLE_TIMEOUT}s). stderr: $(head -5 "$claude_stderr" 2>/dev/null)" ;;
                2)   log "Plan stream ended without completion. stderr: $(head -5 "$claude_stderr" 2>/dev/null)" ;;
                *)   log "Plan command failed (exit $exit_code). stderr: $(head -5 "$claude_stderr" 2>/dev/null)" ;;
            esac
        else
            log "Plan command failed (exit $exit_code). stderr: $(head -5 "$claude_stderr" 2>/dev/null)"
        fi
        log "Claude CLI stdout (first 500): ${raw_output:0:500}"
        return 1
    fi

    # Extract plan from Claude's JSON output .result field
    local plan_content
    plan_content=$(echo "$raw_output" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('result', ''))
except:
    print('')
" 2>/dev/null)

    if [[ -z "$plan_content" || ${#plan_content} -lt 50 ]]; then
        log "Plan output too short or empty (${#plan_content} chars)"
        log "Raw output (first 500): ${raw_output:0:500}"
        return 1
    fi

    echo "$plan_content" > "$plan_file"
    log "Plan written to $plan_file (${#plan_content} chars)"
    echo "$plan_file"
}

revise_plan() {
    local plan_file="$1" feedback="$2" iteration="$3" task_id="$4"
    local rules
    rules=$(cat "$STATE_DIR/RULES.md" 2>/dev/null || echo "No rules file found")
    local current_plan
    current_plan=$(cat "$plan_file")

    local prompt="You are revising an implementation plan that was rejected by the auditor.

CURRENT PLAN:
${current_plan}

AUDITOR FEEDBACK (iteration $iteration):
${feedback}

RULES (coding standards):
${rules}

MANDATORY READS — re-read to fix the auditor's concerns:
1. TASK_QUEUE.md — re-read the FULL task entry and ALL acceptance criteria.
2. .claude/CLAUDE.md — re-check project conventions and referenced spec/docs.
3. Existing source and test files — check for conflicts or patterns you need to follow.

DONE CRITERIA — the revised plan is complete when:
- Every auditor feedback point is explicitly addressed (state what changed and why)
- Every acceptance criterion maps to plan items AND test cases
- Plan follows all conventions described in .claude/CLAUDE.md
- No ambiguities are left unresolved — use [AMBIGUOUS: ...] or [INTERPRETED: ...] tags if spec is unclear

Instructions:
- Output the COMPLETE revised plan in markdown (not just the diff).
- Do NOT implement the code — only revise the plan.
- Do NOT create or modify any source files.
"

    log "Revising plan (iteration $iteration, stream=$NC_USE_STREAM)"
    local raw_output exit_code
    local claude_stderr="$SESSION_DIR/claude_planrev_${task_id}_${iteration}_stderr.log"
    local acc_stderr="$SESSION_DIR/claude_planrev_${task_id}_${iteration}_acc_stderr.log"
    local envelope_path="${LAST_CLAUDE_JSON_PATH:-$SESSION_DIR/last_claude.${task_id}.planrev.${iteration}.json}"
    set +e
    local plan_model="${PLAN_MODEL:-sonnet}"
    if [[ "$NC_USE_STREAM" == "1" ]]; then
        raw_output=$(cd "$PROJECT_PATH" && \
            call_claude_streamed \
                "$PLAN_WALL_TIMEOUT" "$PLAN_IDLE_TIMEOUT" \
                "$envelope_path" "$claude_stderr" "$acc_stderr" \
                "$prompt" \
                --model "$plan_model" \
                ${PLAN_MAX_TURNS:+--max-turns $PLAN_MAX_TURNS})
    else
        raw_output=$(cd "$PROJECT_PATH" && \
            call_claude "$CLAUDE_CLI_TIMEOUT" "$prompt" \
                --model "$plan_model" \
                --output-format json \
                ${PLAN_MAX_TURNS:+--max-turns $PLAN_MAX_TURNS} 2>"$claude_stderr")
    fi
    exit_code=$?
    set -e

    log_claude_cli_cost "$raw_output" "$task_id" "plan-revision"

    if [[ $exit_code -ne 0 ]]; then
        # Stream-only exit codes (125 idle, 2 partial) gated behind the flag.
        if [[ "$NC_USE_STREAM" == "1" ]]; then
            case $exit_code in
                124) log "Plan revision wall-timed-out (${PLAN_WALL_TIMEOUT}s)" ;;
                125) log "Plan revision idle-timed-out (${PLAN_IDLE_TIMEOUT}s)" ;;
                2)   log "Plan revision stream ended without completion" ;;
                *)   log "Plan revision failed (exit $exit_code). stderr: $(head -5 "$claude_stderr" 2>/dev/null)" ;;
            esac
        else
            log "Plan revision failed (exit $exit_code). stderr: $(head -5 "$claude_stderr" 2>/dev/null)"
        fi
        return 1
    fi

    # Extract revised plan from JSON .result and overwrite plan file
    local plan_content
    plan_content=$(echo "$raw_output" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('result', ''))
except:
    print('')
" 2>/dev/null)

    if [[ -z "$plan_content" || ${#plan_content} -lt 50 ]]; then
        log "Revised plan too short or empty (${#plan_content} chars)"
        return 1
    fi

    echo "$plan_content" > "$plan_file"
    log "Revised plan written (${#plan_content} chars)"
    return 0
}

# Codex audit — uses timeout (not run_timed) to preserve stderr separation
audit_plan_call() {
    local plan_file="$1" task_file="$2"

    local raw_output exit_code
    set +e
    raw_output=$(OPENAI_API_KEY="$_OPENAI_KEY" timeout "$CODEX_CALL_TIMEOUT" \
        python3 "$SCRIPTS/call_codex.py" audit-plan \
            --plan "$plan_file" \
            --task-file "$task_file" \
            --rules "$STATE_DIR/RULES.md" \
            --project "$PROJECT_PATH")
    exit_code=$?
    set -e

    if [[ $exit_code -ne 0 ]]; then
        log "Audit command failed (exit $exit_code)"
        return 2
    fi

    if ! echo "$raw_output" | python3 -c "import sys,json;json.load(sys.stdin)" 2>/dev/null; then
        log "Audit returned invalid JSON"
        return 2
    fi

    log_codex_cost "$raw_output"
    echo "$raw_output"
    return 0
}

run_audit() {
    local plan_file="$1" task_file="$2"

    # Degraded mode — skip audit entirely
    if [[ "$CODEX_DEGRADED" == "true" ]]; then
        log "DEGRADED: Skipping audit (Codex unavailable)"
        AUDIT_VERDICT="APPROVED"
        AUDIT_FEEDBACK="[DEGRADED] Audit skipped — Codex unavailable"
        return 0
    fi

    # Retry up to 3 times before degrading
    local attempt rc=1
    AUDIT_RAW=""
    for attempt in 1 2 3; do
        set +e
        AUDIT_RAW=$(audit_plan_call "$plan_file" "$task_file")
        rc=$?
        set -e
        if [[ $rc -eq 0 ]]; then
            break
        fi
        log "RETRY: audit attempt $attempt/3 failed (exit $rc)"
        [[ $attempt -lt 3 ]] && sleep 10
    done

    if [[ $rc -ne 0 ]]; then
        log "WARN: Audit infrastructure failure after 3 attempts — entering degraded mode"
        CODEX_DEGRADED=true
        notify_normal "⚠️ Codex audit unreachable — proceeding without auditor for this session"
        AUDIT_VERDICT="APPROVED"
        AUDIT_FEEDBACK="[DEGRADED] Audit skipped after 3 infrastructure failures (exit $rc)"
        return 0
    fi

    AUDIT_VERDICT=$(echo "$AUDIT_RAW" | python3 -c "import sys,json;print(json.load(sys.stdin).get('verdict','REJECTED'))")
    AUDIT_FEEDBACK=$(echo "$AUDIT_RAW" | python3 -c "import sys,json;print(json.load(sys.stdin).get('feedback',''))")
}

# Classify a review/audit rejection as hard_block or soft_reject.
# Hard blocks are issues where proceeding risks correctness or safety.
# Everything else is a soft reject (style, naming, minor structure).
# Returns via global CLASSIFY_RESULT: approved | hard_block | soft_reject
#
# IMPORTANT: Pattern must match "missing X" or "no X" or "lacks X" or "vulnerable to X"
# to avoid false positives from phrases like "correctly handles reentrancy."
# Each pattern is: (negative context word).{0,30}(security keyword)
# Hard block patterns — configurable via config.sh (append project-specific patterns)
# Default: generic security concerns that apply to any project
HARD_BLOCK_PATTERNS="${HARD_BLOCK_PATTERNS:-(missing|lacks?|no|without|absent|vulnerable to|exposed to|susceptible to).{0,30}(access control|authorization|authentication|input validation|injection protection|overflow protection|rate limiting)}"
HARD_BLOCK_PATTERNS_DIRECT="${HARD_BLOCK_PATTERNS_DIRECT:-privilege.escalation|critical.vulnerabilit|data.loss|data.leak|remote.code.execution|sql.injection|command.injection|auth(entication|orization)?.bypass}"

classify_rejection() {
    local feedback="$1"
    local lower
    lower=$(echo "$feedback" | tr '[:upper:]' '[:lower:]')

    # Direct patterns — always hard block
    local direct_match
    direct_match=$(echo "$lower" | grep -oEi "$HARD_BLOCK_PATTERNS_DIRECT" | head -1) || true
    if [[ -n "$direct_match" ]]; then
        CLASSIFY_RESULT="hard_block"
        log "CLASSIFY: hard_block via direct pattern: '$direct_match'"
        return
    fi

    # Contextual patterns — only hard block when paired with negative framing
    local contextual_match
    contextual_match=$(echo "$lower" | grep -oEi "$HARD_BLOCK_PATTERNS" | head -1) || true
    if [[ -n "$contextual_match" ]]; then
        CLASSIFY_RESULT="hard_block"
        log "CLASSIFY: hard_block via contextual pattern: '$contextual_match'"
        return
    fi

    CLASSIFY_RESULT="soft_reject"
    log "CLASSIFY: soft_reject (no hard block patterns matched)"
}

# Dynamic convergence check — asks LLM if iterations are making progress or going in circles.
# Uses Haiku (cheapest) since this is a simple classification.
# Returns 0 = keep going, 1 = stop (stuck)
CONSECUTIVE_STOPS=0  # tracks consecutive STOP verdicts across convergence checks

check_convergence() {
    local phase="$1"  # "plan" or "implementation"
    shift
    local feedbacks=("$@")
    local count=${#feedbacks[@]}

    # Need at least 5 rounds of feedback before Haiku has enough signal to judge convergence.
    # Below that, it's basically guessing. The iteration cap (MAX_*_ITERATIONS) is the real ceiling.
    (( count < 5 )) && return 0

    # Build feedback history
    local history=""
    local i=1
    for fb in "${feedbacks[@]}"; do
        history+="Round $i: ${fb:0:300}
"
        i=$((i + 1))
    done

    local prompt="You are evaluating whether a code review loop is converging or stuck.

Phase: ${phase}
Rounds so far: ${count}

Feedback history:
${history}

DECIDE:
- CONTINUE if each round is making real progress (new issues found, previous issues resolved)
- STOP if the same core issues keep repeating, feedback is circular, or the reviewer and implementer are talking past each other

RESPOND WITH EXACTLY ONE WORD: CONTINUE or STOP"

    local raw_output
    raw_output=$(cd "$PROJECT_PATH" && \
        call_claude 30 "$prompt" \
            --model sonnet \
            --output-format json \
            --max-turns 1 2>/dev/null) || {
        log "WARN: Convergence check failed — defaulting to CONTINUE (iteration cap is the real safety net)"
        return 0
    }

    # Count Haiku call toward prompt total (shares rate limit window with Sonnet)
    count_prompt

    local answer
    answer=$(echo "$raw_output" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    r = data.get('result', '').strip().upper()
    print('STOP' if 'STOP' in r else 'CONTINUE')
except:
    print('CONTINUE')
" 2>/dev/null)

    if [[ "$answer" == "STOP" ]]; then
        CONSECUTIVE_STOPS=$((CONSECUTIVE_STOPS + 1))
        if (( CONSECUTIVE_STOPS >= 2 )); then
            log "Convergence check: 2 consecutive STOPs after $count rounds — stuck"
            notify_normal "⚠️ ${phase} stuck after ${count} rounds — capping iterations"
            return 1
        fi
        log "Convergence check: STOP (1 of 2 needed, continuing)"
        return 0
    fi

    CONSECUTIVE_STOPS=0  # reset on any CONTINUE
    log "Convergence check: CONTINUE (round $count making progress)"
    return 0
}

plan_loop() {
    local task_file="$1" task_id="$2"
    local plan_file iteration=0
    local -a feedbacks=()
    PLAN_AUDIT_MODE="approved"
    CONSECUTIVE_STOPS=0  # reset for this loop

    # A6: on the streamed path only, parent owns the envelope path so we
    # can recover partial output from disk if the subshell is killed
    # before it can echo. On the legacy path we keep LAST_CLAUDE_JSON_PATH
    # unset so flag-off behavior is byte-identical.
    unset LAST_CLAUDE_JSON_PATH
    if [[ "$NC_USE_STREAM" == "1" ]]; then
        LAST_CLAUDE_JSON_PATH="$SESSION_DIR/last_claude.${task_id}.plan.json"
    fi
    plan_file=$(plan_task "$task_file" "$task_id") || return 1
    [[ -z "$plan_file" ]] && return 1

    while (( iteration < MAX_PLAN_ITERATIONS )); do
        iteration=$((iteration + 1))

        run_audit "$plan_file" "$task_file"
        journal '{"event":"plan_audited","task_id":"'"$task_id"'","verdict":"'"$AUDIT_VERDICT"'","iteration":'"$iteration"'}'

        if [[ "$AUDIT_VERDICT" == "APPROVED" ]]; then
            PLAN_AUDIT_MODE="approved"
            journal '{"event":"plan_approved","task_id":"'"$task_id"'"}'
            PLAN_FILE="$plan_file"
            return 0
        fi

        # Classify rejection
        classify_rejection "$AUDIT_FEEDBACK"

        if [[ "$CLASSIFY_RESULT" == "hard_block" ]]; then
            log "HARD BLOCK: Plan rejected with safety/correctness concern (iteration $iteration): ${AUDIT_FEEDBACK:0:200}"
            PLAN_AUDIT_MODE="hard_block"
            journal '{"event":"plan_hard_block","task_id":"'"$task_id"'","iteration":'"$iteration"'}'
            return 1
        fi

        feedbacks+=("$AUDIT_FEEDBACK")
        log "Plan soft-rejected (iteration $iteration): ${AUDIT_FEEDBACK:0:200}"

        # Dynamic convergence check — stop early if stuck, keep going if progressing
        if (( iteration >= MAX_PLAN_ITERATIONS )) || ! check_convergence "plan audit" "${feedbacks[@]}"; then
            break
        fi

        if [[ "$NC_USE_STREAM" == "1" ]]; then
            LAST_CLAUDE_JSON_PATH="$SESSION_DIR/last_claude.${task_id}.planrev.${iteration}.json"
        fi
        if ! revise_plan "$plan_file" "$AUDIT_FEEDBACK" "$iteration" "$task_id"; then
            log "Plan revision failed"
            feedbacks+=("Plan revision command failed")
        fi
    done

    # Iterations exhausted or convergence check said stop — escalate to Opus
    if [[ "${PLAN_MODEL:-sonnet}" != "opus" ]]; then
        log "plan_loop: Sonnet stuck after $iteration iterations — escalating to Opus"
        notify_normal "🧠 Escalating plan to Opus ($task_id stuck after ${iteration} rounds)"
        PLAN_MODEL="opus"
        journal '{"event":"plan_escalate_opus","task_id":"'"$task_id"'","iteration":'"$iteration"'}'

        # One Opus re-plan attempt with accumulated feedback
        local all_feedback=""
        for fb in "${feedbacks[@]}"; do
            all_feedback+="$fb
---
"
        done
        if [[ "$NC_USE_STREAM" == "1" ]]; then
            LAST_CLAUDE_JSON_PATH="$SESSION_DIR/last_claude.${task_id}.planrev.opus.json"
        fi
        if revise_plan "$plan_file" "$all_feedback" "$iteration" "$task_id"; then
            # Run one more audit on the Opus plan
            run_audit "$plan_file" "$task_file"
            if [[ "$AUDIT_VERDICT" == "APPROVED" ]]; then
                PLAN_AUDIT_MODE="approved"
                PLAN_MODEL="sonnet"  # reset for next task
                PLAN_FILE="$plan_file"
                log "plan_loop: Opus rescue plan approved"
                return 0
            fi
            log "plan_loop: Opus rescue plan not approved — proceeding anyway"
        else
            log "plan_loop: Opus rescue plan failed"
        fi
        PLAN_MODEL="sonnet"  # reset for next task
    fi

    # Proceed with best available plan
    log "plan_loop: capped after $iteration iterations — proceeding with best plan"
    PLAN_AUDIT_MODE="capped_soft_reject"
    PLAN_LAST_FEEDBACK="$AUDIT_FEEDBACK"
    journal '{"event":"plan_capped_soft_reject","task_id":"'"$task_id"'","iteration":'"$iteration"',"last_feedback":"'"$(echo "$AUDIT_FEEDBACK" | head -c 500 | sed 's/"/\\"/g')"'"}'
    PLAN_FILE="$plan_file"
    return 0
}

# =============================================================================
# SEC 6: Phase B — Implement
# =============================================================================

implement_task() {
    local plan_file="$1" project_path="$2" task_id="$3"
    local plan rules prompt

    plan=$(cat "$plan_file")
    rules=$(cat "$STATE_DIR/RULES.md" 2>/dev/null || echo "No rules file found")
    local learnings
    learnings=$(get_session_learnings 2>/dev/null || true)

    prompt="You are implementing a task for a ${PROJECT_DESC} project.

PLAN (your primary source of truth — implement exactly this):
${plan}
${learnings}
RULES (coding standards — follow these for style and patterns):
${rules}

DONE CRITERIA — implementation is complete when ALL of these are true:
- Every file, function, component, and test from the plan exists
- If you modified any dependency file (package.json, requirements.txt, Cargo.toml, etc.), run '$INSTALL_CMD' before building
- '$BUILD_CMD' compiles/builds with zero errors
- '$TEST_CMD' passes with zero failures
- No files outside the plan's scope are modified
- No extra files or features beyond the plan

UNCERTAINTY PROTOCOL:
- If the plan is unclear on a specific behavior, implement the safest/simplest interpretation and add a comment: // TODO: spec ambiguity — [description]
- If you hit a build error from the plan's design, fix it minimally and note the deviation

Instructions:
- Implement exactly what the plan says. No more, no less.
- Be context-efficient: read only the files you need, avoid re-reading files you've already seen. Context is limited.
- $VERIFY_INSTRUCTIONS
- Do NOT create throwaway/scratch/probe files.
"

    log "Implementing $task_id"
    update_status "implementing $task_id"
    notify_normal "🔨 Implementing $task_id"

    # Legacy path: `timeout` wrapper (no idle timer — JSON mode produces no
    # intermediate output, so idle would fire prematurely). Streamed path:
    # run_with_timeout.py wraps claude | accumulator; heartbeats reset idle.
    # cd into project dir instead of --cwd (not supported on all CLI versions).
    local raw_output exit_code
    local claude_stderr="$SESSION_DIR/claude_impl_${task_id}_stderr.log"
    local acc_stderr="$SESSION_DIR/claude_impl_${task_id}_acc_stderr.log"
    # Parent-owned envelope path: impl_loop sets LAST_CLAUDE_JSON_PATH before
    # calling us so it can read the partial envelope from disk after a
    # timeout. Fall back to a default if somehow unset.
    local envelope_path="${LAST_CLAUDE_JSON_PATH:-$SESSION_DIR/last_claude.${task_id}.impl.unknown.json}"
    set +e
    if [[ "$NC_USE_STREAM" == "1" ]]; then
        raw_output=$(cd "$project_path" && \
            call_claude_streamed \
                "$IMPL_WALL_TIMEOUT" "$IMPL_IDLE_TIMEOUT" \
                "$envelope_path" "$claude_stderr" "$acc_stderr" \
                "$prompt" \
                --model sonnet \
                ${IMPL_MAX_TURNS:+--max-turns $IMPL_MAX_TURNS})
    else
        raw_output=$(cd "$project_path" && \
            call_claude "$CLAUDE_CLI_TIMEOUT" "$prompt" \
                --model sonnet \
                --output-format json \
                ${IMPL_MAX_TURNS:+--max-turns $IMPL_MAX_TURNS} 2>"$claude_stderr")
    fi
    exit_code=$?
    set -e

    if [[ $exit_code -ne 0 ]]; then
        # Only the streamed path can emit 125 (idle) / 2 (partial stream);
        # on the legacy path those codes mean something else, so keep the
        # diagnostic generic there.
        if [[ "$NC_USE_STREAM" == "1" ]]; then
            case $exit_code in
                124) log "Impl wall-timed-out (${IMPL_WALL_TIMEOUT}s). stderr: $(head -5 "$claude_stderr" 2>/dev/null)" ;;
                125) log "Impl idle-timed-out (${IMPL_IDLE_TIMEOUT}s). stderr: $(head -5 "$claude_stderr" 2>/dev/null)" ;;
                2)   log "Impl stream ended without completion. stderr: $(head -5 "$claude_stderr" 2>/dev/null)" ;;
                *)   log "Claude CLI exited $exit_code. stderr: $(head -5 "$claude_stderr" 2>/dev/null)" ;;
            esac
        else
            log "Claude CLI exited $exit_code. stderr: $(head -5 "$claude_stderr" 2>/dev/null)"
        fi
        log "Claude CLI stdout (first 500): ${raw_output:0:500}"
    fi

    record_touched_files
    log_claude_cli_cost "$raw_output" "$task_id" "implementation"

    return $exit_code
}

revise_impl() {
    local plan_file="$1" feedback="$2" iteration="$3"
    local plan rules prompt

    plan=$(cat "$plan_file")
    rules=$(cat "$STATE_DIR/RULES.md" 2>/dev/null || echo "No rules file found")
    local learnings
    learnings=$(get_session_learnings 2>/dev/null || true)

    prompt="You are revising an implementation that was rejected by the code reviewer.

PLAN (the approved design — your changes must still match this):
${plan}

REVIEWER FEEDBACK (iteration $iteration):
${feedback}
${learnings}
RULES (coding standards):
${rules}

DONE CRITERIA — revision is complete when:
- Every reviewer feedback point is addressed
- If you modified any package.json, run '$INSTALL_CMD' before building
- '$BUILD_CMD' compiles with zero errors
- '$TEST_CMD' passes with zero failures
- Changes stay within the plan's scope

Instructions:
- Address EVERY point in the reviewer's feedback.
- $VERIFY_INSTRUCTIONS
- Do NOT modify files outside the plan's scope.
"

    log "Revising implementation (iteration $iteration)"
    update_status "revising $TASK_ID (iteration $iteration)"
    notify_normal "🔄 Revising $TASK_ID (round $iteration)"

    # Legacy path: `timeout` wrapper (no idle timer — JSON mode produces no
    # intermediate output, so idle would fire prematurely). Streamed path:
    # run_with_timeout.py wraps claude | accumulator; heartbeats reset idle.
    local raw_output exit_code
    local claude_stderr="$SESSION_DIR/claude_rev_${TASK_ID}_${iteration}_stderr.log"
    local acc_stderr="$SESSION_DIR/claude_rev_${TASK_ID}_${iteration}_acc_stderr.log"
    # Parent-owned envelope path: impl_loop sets LAST_CLAUDE_JSON_PATH before
    # calling us so it can read the partial envelope from disk after a
    # timeout. Fall back to a default if somehow unset.
    local envelope_path="${LAST_CLAUDE_JSON_PATH:-$SESSION_DIR/last_claude.${TASK_ID}.revimpl.${iteration}.json}"
    set +e
    if [[ "$NC_USE_STREAM" == "1" ]]; then
        raw_output=$(cd "$PROJECT_PATH" && \
            call_claude_streamed \
                "$IMPL_WALL_TIMEOUT" "$IMPL_IDLE_TIMEOUT" \
                "$envelope_path" "$claude_stderr" "$acc_stderr" \
                "$prompt" \
                --model sonnet \
                ${IMPL_MAX_TURNS:+--max-turns $IMPL_MAX_TURNS})
    else
        raw_output=$(cd "$PROJECT_PATH" && \
            call_claude "$CLAUDE_CLI_TIMEOUT" "$prompt" \
                --model sonnet \
                --output-format json \
                ${IMPL_MAX_TURNS:+--max-turns $IMPL_MAX_TURNS} 2>"$claude_stderr")
    fi
    exit_code=$?
    set -e

    if [[ $exit_code -ne 0 ]]; then
        # See implement_task — stream-only exit codes gated behind the flag.
        if [[ "$NC_USE_STREAM" == "1" ]]; then
            case $exit_code in
                124) log "Revimpl wall-timed-out (${IMPL_WALL_TIMEOUT}s). stderr: $(head -5 "$claude_stderr" 2>/dev/null)" ;;
                125) log "Revimpl idle-timed-out (${IMPL_IDLE_TIMEOUT}s). stderr: $(head -5 "$claude_stderr" 2>/dev/null)" ;;
                2)   log "Revimpl stream ended without completion. stderr: $(head -5 "$claude_stderr" 2>/dev/null)" ;;
                *)   log "Claude CLI exited $exit_code. stderr: $(head -5 "$claude_stderr" 2>/dev/null)" ;;
            esac
        else
            log "Claude CLI exited $exit_code. stderr: $(head -5 "$claude_stderr" 2>/dev/null)"
        fi
        log "Claude CLI stdout (first 500): ${raw_output:0:500}"
    fi

    record_touched_files
    log_claude_cli_cost "$raw_output" "$TASK_ID" "revision"

    return $exit_code
}

# Codex review — uses timeout (not run_timed) to preserve stderr separation
review_impl() {
    local plan_file="$1"

    local raw_output exit_code
    set +e
    raw_output=$(OPENAI_API_KEY="$_OPENAI_KEY" timeout "$CODEX_CALL_TIMEOUT" \
        python3 "$SCRIPTS/call_codex.py" review-impl \
            --project "$PROJECT_PATH" \
            --plan "$plan_file" \
            --rules "$STATE_DIR/RULES.md")
    exit_code=$?
    set -e

    if [[ $exit_code -ne 0 ]]; then
        log "Review command failed (exit $exit_code)"
        return 2
    fi

    if ! echo "$raw_output" | python3 -c "import sys,json;json.load(sys.stdin)" 2>/dev/null; then
        log "Review returned invalid JSON"
        return 2
    fi

    log_codex_cost "$raw_output"
    echo "$raw_output"
    return 0
}

run_review() {
    local plan_file="$1"

    # Degraded mode — skip review entirely
    if [[ "$CODEX_DEGRADED" == "true" ]]; then
        log "DEGRADED: Skipping review (Codex unavailable)"
        REVIEW_VERDICT="APPROVED"
        REVIEW_FEEDBACK="[DEGRADED] Review skipped — Codex unavailable"
        return 0
    fi

    # Retry up to 3 times before degrading
    local attempt rc=1
    REVIEW_RAW=""
    for attempt in 1 2 3; do
        set +e
        REVIEW_RAW=$(review_impl "$plan_file")
        rc=$?
        set -e
        if [[ $rc -eq 0 ]]; then
            break
        fi
        log "RETRY: review attempt $attempt/3 failed (exit $rc)"
        [[ $attempt -lt 3 ]] && sleep 10
    done

    if [[ $rc -ne 0 ]]; then
        log "WARN: Review infrastructure failure after 3 attempts — entering degraded mode"
        CODEX_DEGRADED=true
        notify_normal "⚠️ Codex review unreachable — proceeding without reviewer for this session"
        REVIEW_VERDICT="APPROVED"
        REVIEW_FEEDBACK="[DEGRADED] Review skipped after 3 infrastructure failures (exit $rc)"
        return 0
    fi

    REVIEW_VERDICT=$(echo "$REVIEW_RAW" | python3 -c "import sys,json;print(json.load(sys.stdin).get('verdict','REJECTED'))")
    REVIEW_FEEDBACK=$(echo "$REVIEW_RAW" | python3 -c "import sys,json;print(json.load(sys.stdin).get('feedback',''))")
}

check_impl_lock() {
    local feedbacks_json
    feedbacks_json=$(printf '%s\n' "$@" | python3 -c "import sys,json;print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))" 2>/dev/null)

    local lock_result
    set +e
    lock_result=$(python3 "$SCRIPTS/lock_detect.py" check --feedbacks "$feedbacks_json" 2>/dev/null)
    set -e

    if echo "$lock_result" | grep -q '"locked": true' 2>/dev/null; then
        return 1
    fi
    return 0
}

impl_loop() {
    local plan_file="$1" task_id="$2"
    local -a feedbacks=()
    local iteration=0
    local reviews_reached=0
    CONSECUTIVE_STOPS=0  # reset for this loop
    IMPL_REVIEW_MODE="approved"
    REVIEW_FEEDBACK=""
    # Clear any stale envelope path from a prior loop — the streamed
    # branch below will set it fresh per iteration; the legacy path
    # never reads it.
    unset LAST_CLAUDE_JSON_PATH

    while (( iteration < MAX_IMPL_ITERATIONS )); do
        iteration=$((iteration + 1))

        # A6: on the streamed path, parent owns the envelope path so we
        # can recover partial output from disk even if the subshell is
        # killed before it can echo. stream-accumulator.py writes the
        # envelope atomically on every state change and on exit; on
        # SIGKILL the last-written snapshot remains readable. The legacy
        # path does not write an envelope, so we only set this when the
        # flag is on — keeps NC_USE_STREAM=0 behavior byte-identical.
        if [[ "$NC_USE_STREAM" == "1" ]]; then
            if [[ $iteration -eq 1 ]]; then
                LAST_CLAUDE_JSON_PATH="$SESSION_DIR/last_claude.${task_id}.impl.${iteration}.json"
            else
                LAST_CLAUDE_JSON_PATH="$SESSION_DIR/last_claude.${task_id}.revimpl.${iteration}.json"
            fi
        fi

        local impl_rc=0
        if [[ $iteration -eq 1 ]]; then
            set +e
            implement_task "$plan_file" "$PROJECT_PATH" "$task_id"
            impl_rc=$?
            set -e
        else
            set +e
            revise_impl "$plan_file" "${feedbacks[-1]}" "$iteration"
            impl_rc=$?
            set -e
        fi

        if [[ $impl_rc -ne 0 ]]; then
            if [[ "$NC_USE_STREAM" == "1" ]]; then
                # Streamed-path recovery: on timeout / partial-stream
                # exits, read whatever text the model produced from the
                # envelope file and feed it back so the next iteration
                # has context instead of flying blind. Claude sometimes
                # finishes the work even when killed mid-stream; the
                # partial envelope captures assistant text up to that
                # point.
                case $impl_rc in
                    124|125|2)
                        local partial_txt=""
                        if [[ -f "$LAST_CLAUDE_JSON_PATH" ]]; then
                            # Verify it's actually our envelope before
                            # trusting .result — defends against a stale
                            # file from a prior run sharing the path.
                            partial_txt=$(python3 -c "
import json, sys
try:
    e = json.load(open('$LAST_CLAUDE_JSON_PATH'))
    if not e.get('_envelope'):
        sys.exit(0)
    r = e.get('result') or ''
    print(r[:4000])
except Exception as ex:
    sys.stderr.write(f'partial extract failed: {ex}\n')
" 2>/dev/null)
                        fi
                        local tag
                        case $impl_rc in
                            124) tag="wall-timeout" ;;
                            125) tag="idle-timeout" ;;
                            2)   tag="stream-ended-partial" ;;
                        esac
                        log "Implementation exited $impl_rc ($tag). Recovered ${#partial_txt} chars of partial output."
                        if [[ -n "$partial_txt" ]]; then
                            feedbacks+=("[$tag, iteration $iteration] Implementation was killed before completion. Partial model output recovered from stream envelope (first 4000 chars):
---
$partial_txt
---
Resume from here and finish the remaining work.")
                        else
                            feedbacks+=("[$tag, iteration $iteration] Implementation killed with no recoverable output. Retry with smaller scope or different approach.")
                        fi
                        journal '{"event":"impl_partial_recovered","task_id":"'"$task_id"'","iteration":'"$iteration"',"exit":'"$impl_rc"',"bytes":'"${#partial_txt}"'}'
                        continue
                        ;;
                    *)
                        log "Implementation failed (exit $impl_rc)"
                        if [[ $iteration -eq 1 ]]; then
                            feedbacks+=("Implementation command failed (exit $impl_rc)")
                        else
                            feedbacks+=("Revision command failed (exit $impl_rc)")
                        fi
                        continue
                        ;;
                esac
            else
                # Legacy path — preserve pre-A6 behavior exactly.
                if [[ $iteration -eq 1 ]]; then
                    log "Implementation failed"
                    feedbacks+=("Implementation command failed")
                else
                    log "Revision failed"
                    feedbacks+=("Revision command failed")
                fi
                continue
            fi
        fi

        record_touched_files

        run_review "$plan_file"
        reviews_reached=$((reviews_reached + 1))
        journal '{"event":"impl_reviewed","task_id":"'"$task_id"'","verdict":"'"$REVIEW_VERDICT"'","iteration":'"$iteration"'}'

        if [[ "$REVIEW_VERDICT" != "APPROVED" ]]; then
            # Classify rejection
            classify_rejection "$REVIEW_FEEDBACK"

            if [[ "$CLASSIFY_RESULT" == "hard_block" ]]; then
                log "HARD BLOCK: Impl rejected with safety/correctness concern (iteration $iteration): ${REVIEW_FEEDBACK:0:200}"
                IMPL_REVIEW_MODE="hard_block"
                journal '{"event":"impl_hard_block","task_id":"'"$task_id"'","iteration":'"$iteration"'}'
                return 1
            fi

            feedbacks+=("$REVIEW_FEEDBACK")
            log "Impl soft-rejected (iteration $iteration): ${REVIEW_FEEDBACK:0:200}"

            # Dynamic convergence — ask Haiku if we're making progress
            if ! check_convergence "implementation review" "${feedbacks[@]}"; then
                log "Convergence check: implementation loop is stuck — stopping"
                IMPL_REVIEW_MODE="capped"
                journal '{"event":"impl_convergence_stop","task_id":"'"$task_id"'","iteration":'"$iteration"'}'
                break
            fi
            continue
        fi

        # APPROVED — check scope before accepting
        if ! verify_impl_scope; then
            log "Scope violations cleaned — re-testing and re-reviewing"

            set +e
            run_timed $BUILD_WALL $BUILD_IDLE $BUILD_CMD
            local build_ok=$?
            run_timed $TEST_WALL $TEST_IDLE $TEST_CMD
            local test_ok=$?
            set -e

            if [[ $build_ok -ne 0 ]] || [[ $test_ok -ne 0 ]]; then
                feedbacks+=("Scope cleanup broke build/tests")
                if ! check_convergence "implementation review" "${feedbacks[@]}"; then
                    log "Convergence check: stuck after scope cleanup failures — stopping"
                    IMPL_REVIEW_MODE="capped"
                    break
                fi
                continue
            fi

            run_review "$plan_file"

            if [[ "$REVIEW_VERDICT" != "APPROVED" ]]; then
                feedbacks+=("Post-scope-cleanup re-review: $REVIEW_FEEDBACK")
                if ! check_convergence "implementation review" "${feedbacks[@]}"; then
                    log "Convergence check: stuck after scope re-review — stopping"
                    IMPL_REVIEW_MODE="capped"
                    break
                fi
                continue
            fi
        fi

        IMPL_REVIEW_MODE="approved"
        journal '{"event":"impl_approved","task_id":"'"$task_id"'"}'
        return 0
    done

    # Iterations exhausted — distinguish implementation failures from soft rejections
    if [[ $reviews_reached -eq 0 ]]; then
        log "impl_loop: all $iteration iterations failed before reaching review — implementation broken"
        IMPL_REVIEW_MODE="hard_block"
        return 1
    fi

    log "impl_loop: 3 iterations exhausted — checking local safety gates"

    # Scope must be clean
    if ! verify_impl_scope; then
        log "Scope violations remain after cleanup — cannot proceed"
    fi

    # Build must pass
    set +e
    cd "$PROJECT_PATH"
    run_timed $BUILD_WALL $BUILD_IDLE $BUILD_CMD
    local cap_build=$?
    run_timed $TEST_WALL $TEST_IDLE $TEST_CMD
    local cap_test=$?
    set -e

    if [[ $cap_build -ne 0 ]] || [[ $cap_test -ne 0 ]]; then
        log "Local verification failed after 3 soft rejections — cannot proceed"
        return 1
    fi

    # All local gates passed — proceed with warning
    log "impl_loop: 3 soft rejections exhausted — local verification passed, proceeding"
    IMPL_REVIEW_MODE="capped_soft_reject"
    IMPL_LAST_FEEDBACK="${REVIEW_FEEDBACK:-no review feedback available}"
    local safe_feedback
    safe_feedback=$(echo "${REVIEW_FEEDBACK:-}" | head -c 500 | sed 's/"/\\"/g')
    journal '{"event":"impl_capped_soft_reject","task_id":"'"$task_id"'","iteration":'"$iteration"',"last_feedback":"'"$safe_feedback"'"}'
    return 0
}

# =============================================================================
# SEC 7: Phase C — Commit
# =============================================================================

commit_and_close_task() {
    local task_id="$1" description="$2" degraded_note="${3:-}"
    mark_task_done_in_queue "$task_id"
    append_to_progress "$task_id" "$degraded_note"
    cd "$PROJECT_PATH"
    git add -A

    # Ghost-commit guard: reject if only bookkeeping files changed (no actual code produced)
    local code_files
    code_files=$(git diff --cached --name-only | grep -cvE '^(TASK_QUEUE\.md|PROGRESS\.md|SESSION_PROGRESS\.md|memory\.md|\.nightcrawler/)$' || true)
    if [[ "$code_files" -eq 0 ]]; then
        log "GHOST-COMMIT BLOCKED: $task_id — only bookkeeping files staged, no code produced"
        git reset HEAD -- . >/dev/null 2>&1
        # Undo the queue/progress marks
        git checkout HEAD -- TASK_QUEUE.md PROGRESS.md 2>/dev/null || true
        echo "GHOST"
        return 1
    fi

    local commit_msg="[nightcrawler] feat($task_id): $description

Task: $task_id
Session: $SESSION_ID
Cost: \$${TASK_COST}"
    if [[ -n "$degraded_note" ]]; then
        commit_msg="${commit_msg}
Note: $(echo -e "$degraded_note" | head -1)"
    fi

    git commit -m "$commit_msg" >/dev/null
    local hash
    hash=$(git rev-parse HEAD)
    journal '{"event":"task_committed","task_id":"'"$task_id"'","commit":"'"$hash"'","ts":"'"$(date -u +%FT%TZ)"'"}'
    echo "$hash"
}

verify_post_commit() {
    local task_id="$1" commit_hash="$2"
    cd "$PROJECT_PATH"

    set +e
    run_timed $BUILD_WALL $BUILD_IDLE $BUILD_CMD
    local b=$?
    run_timed $TEST_WALL $TEST_IDLE $TEST_CMD
    local t=$?
    set -e

    if [[ $b -ne 0 ]] || [[ $t -ne 0 ]]; then
        return 1
    fi

    journal '{"event":"task_verified","task_id":"'"$task_id"'","commit":"'"$commit_hash"'"}'
    return 0
}

handle_post_commit_failure() {
    local task_id="$1" commit_hash="$2" revert_count="$3"

    log "Post-commit verification failed for $task_id (revert $revert_count)"
    cd "$PROJECT_PATH"
    git revert --no-edit "$commit_hash"

    if [[ $revert_count -ge 2 ]]; then
        log "LOCKED: $task_id failed post-commit verification twice"
        escalate_urgent "LOCKED ($PROJECT): $task_id failed post-commit verification 2x after revert"
        return 1
    fi

    return 0
}

# =============================================================================
# SEC 8: Recovery
# =============================================================================

discover_recovery_needs() {
    local sessions_dir="$STATE_DIR/sessions"
    RECOVERY_NEEDED=false

    [[ -d "$sessions_dir" ]] || return 0

    # Find most recent session journal for this project
    local latest_journal="" latest_session=""
    local d
    for d in "$sessions_dir"/*-"$PROJECT"; do
        if [[ -f "$d/journal.jsonl" ]]; then
            latest_journal="$d/journal.jsonl"
            latest_session=$(basename "$d")
        fi
    done

    [[ -z "$latest_journal" ]] && return 0

    # Check if last session completed cleanly
    if grep -q '"event":"session_complete"' "$latest_journal" 2>/dev/null || \
       grep -q '"event": "session_complete"' "$latest_journal" 2>/dev/null; then
        return 0
    fi

    RECOVERY_NEEDED=true
    RECOVERY_SESSION_ID="$latest_session"

    # Parse last event
    local last_line
    last_line=$(tail -1 "$latest_journal" 2>/dev/null || echo "")

    RECOVERY_LAST_EVENT=$(echo "$last_line" | python3 -c "
import sys,json
try:
    print(json.load(sys.stdin).get('event','unknown'))
except:
    print('unknown')
" 2>/dev/null)

    RECOVERY_TASK_ID=$(echo "$last_line" | python3 -c "
import sys,json
try:
    print(json.load(sys.stdin).get('task_id',''))
except:
    print('')
" 2>/dev/null)

    RECOVERY_COMMIT=$(echo "$last_line" | python3 -c "
import sys,json
try:
    print(json.load(sys.stdin).get('commit',''))
except:
    print('')
" 2>/dev/null)

    log "RECOVERY: Previous session $RECOVERY_SESSION_ID did not complete (last event: $RECOVERY_LAST_EVENT)"
}

execute_recovery() {
    [[ "$RECOVERY_NEEDED" != "true" ]] && return 0

    local current_branch
    current_branch=$(git -C "$PROJECT_PATH" rev-parse --abbrev-ref HEAD)
    if [[ "$current_branch" != "nightcrawler/dev" ]]; then
        die "Recovery needs nightcrawler/dev but on '$current_branch'"
    fi

    case "$RECOVERY_LAST_EVENT" in
        task_committed)
            if [[ -n "$RECOVERY_COMMIT" ]] && git -C "$PROJECT_PATH" cat-file -e "$RECOVERY_COMMIT" 2>/dev/null; then
                log "RECOVERY: Found unverified commit $RECOVERY_COMMIT for $RECOVERY_TASK_ID"
                cd "$PROJECT_PATH"
                set +e
                run_timed $BUILD_WALL $BUILD_IDLE $BUILD_CMD
                local b=$?
                run_timed $TEST_WALL $TEST_IDLE $TEST_CMD
                local t=$?
                set -e
                if [[ $b -eq 0 ]] && [[ $t -eq 0 ]]; then
                    log "RECOVERY: Commit $RECOVERY_COMMIT passes verification"
                    journal '{"event":"task_verified","task_id":"'"$RECOVERY_TASK_ID"'","commit":"'"$RECOVERY_COMMIT"'","recovery":true}'
                else
                    log "RECOVERY: Commit $RECOVERY_COMMIT failed verification, reverting"
                    git -C "$PROJECT_PATH" revert --no-edit "$RECOVERY_COMMIT"
                fi
            else
                log "RECOVERY: Commit ${RECOVERY_COMMIT:-empty} not found (hard crash before commit landed)"
            fi
            ;;
        task_start|plan_approved|impl_approved)
            log "RECOVERY: Task $RECOVERY_TASK_ID was in progress, resetting to queued"
            ;;
        *)
            log "RECOVERY: Unknown last event '$RECOVERY_LAST_EVENT', proceeding cautiously"
            ;;
    esac

    # Revert previous session's owned files using content-verified manifest
    local prev_touched="$CONTROL_DIR/touched_files"
    if [[ -f "$prev_touched" ]]; then
        local saved="$TOUCHED_FILES"
        TOUCHED_FILES="$prev_touched"
        revert_owned_files
        TOUCHED_FILES="$saved"
    fi

    # Reset stale [~] markers
    local -a recovery_expected=()
    if [[ -f "$PROJECT_PATH/TASK_QUEUE.md" ]]; then
        if grep -q '\[~\]' "$PROJECT_PATH/TASK_QUEUE.md"; then
            sed -i 's/\[~\]/[ ]/g' "$PROJECT_PATH/TASK_QUEUE.md"
            recovery_expected+=("TASK_QUEUE.md")
            log "RECOVERY: Reset stale [~] markers"
        fi
    fi

    # Commit ONLY expected recovery mutations
    cd "$PROJECT_PATH"
    local unexpected=false
    local dirty_files
    dirty_files=$(git diff --name-only HEAD -- 2>/dev/null; git diff --name-only --cached HEAD -- 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)

    while IFS= read -r dirty_file; do
        [[ -z "$dirty_file" ]] && continue
        local is_expected=false
        local exp
        for exp in "${recovery_expected[@]+"${recovery_expected[@]}"}"; do
            if [[ "$dirty_file" == "$exp" ]]; then
                is_expected=true
                break
            fi
        done
        if [[ "$is_expected" != "true" ]]; then
            log "RECOVERY: Unexpected dirty file: $dirty_file"
            unexpected=true
        fi
    done <<< "$dirty_files"

    if [[ "$unexpected" == "true" ]]; then
        die "Recovery found unexpected dirty files — manual cleanup needed before Nightcrawler can run"
    fi

    if [[ ${#recovery_expected[@]} -gt 0 ]]; then
        git add -- "${recovery_expected[@]}"
        git commit -m "[nightcrawler] recovery: reconcile session $RECOVERY_SESSION_ID"
        log "RECOVERY: Committed recovery mutations"
    fi
}

# =============================================================================
# SEC 9: Startup
# =============================================================================

switch_to_dev() {
    local current base
    current=$(git -C "$PROJECT_PATH" rev-parse --abbrev-ref HEAD)
    base="${BASE_BRANCH:-main}"

    case "$current" in
        "$base")
            if git -C "$PROJECT_PATH" rev-parse --verify nightcrawler/dev &>/dev/null; then
                log "On $base — switching to existing nightcrawler/dev"
                git -C "$PROJECT_PATH" checkout nightcrawler/dev
            else
                log "First session — creating nightcrawler/dev from $base"
                git -C "$PROJECT_PATH" checkout -B nightcrawler/dev "$base"
            fi
            ;;
        "nightcrawler/dev")
            log "Already on nightcrawler/dev"
            ;;
        *)
            die "On unexpected branch '$current' — expected $base or nightcrawler/dev"
            ;;
    esac
}

sync_with_main() {
    local base="${BASE_BRANCH:-main}"
    log "Fetching latest from origin"
    git -C "$PROJECT_PATH" fetch origin "$base" nightcrawler/dev 2>/dev/null || log "WARN: fetch failed (offline?)"

    # Pull any remote changes to nightcrawler/dev first (e.g. task queue edits pushed directly)
    if git -C "$PROJECT_PATH" rev-parse --verify origin/nightcrawler/dev &>/dev/null; then
        git -C "$PROJECT_PATH" merge origin/nightcrawler/dev --no-edit 2>/dev/null || true
    fi

    # Merge origin/<base> into nightcrawler/dev
    log "Merging origin/$base into nightcrawler/dev"
    if ! git -C "$PROJECT_PATH" merge "origin/$base" --no-edit 2>/dev/null; then
        # Conflict — try auto-resolving by preferring our (nightcrawler/dev) version for TASK_QUEUE.md
        log "WARN: merge conflict with origin/$base — attempting auto-resolve"
        git -C "$PROJECT_PATH" checkout --ours -- TASK_QUEUE.md 2>/dev/null || true
        git -C "$PROJECT_PATH" add TASK_QUEUE.md 2>/dev/null || true
        if ! git -C "$PROJECT_PATH" -c core.editor=true merge --continue 2>/dev/null; then
            git -C "$PROJECT_PATH" merge --abort 2>/dev/null || true
            log "WARN: merge with origin/$base failed — continuing on current nightcrawler/dev (out of sync)"
            escalate_urgent "WARNING ($PROJECT): Could not merge origin/$base — session running on stale nightcrawler/dev"
            return
        fi
        log "Auto-resolved merge conflict (kept nightcrawler/dev TASK_QUEUE.md)"
    fi
    log "nightcrawler/dev synced with origin/$base"
}

startup() {
    # 1. flock
    source "$SCRIPTS/_lock.sh"
    exec 200>"$LOCKFILE"
    nc_flock_fd 200 || die "Another session running (lock held on $LOCKFILE)"
    echo "$$" >&200

    # 2. Create control dir (SESSION_DIR already created at init)
    mkdir -p "$CONTROL_DIR"

    # 3. Discover recovery needs (read-only)
    discover_recovery_needs

    # 4. Pre-switch worktree safety
    require_clean_worktree_for_switch

    # 5. Switch to dev
    switch_to_dev

    # 6. Execute recovery
    execute_recovery

    # 6b. Rotate manifest
    rotate_manifest

    # 7. Sync with main
    sync_with_main

    # 8. Clean worktree — auto-commit stray changes from sync/recovery/manual fixes
    if [[ -n "$(git -C "$PROJECT_PATH" status --porcelain 2>/dev/null)" ]]; then
        log "Worktree dirty after sync — auto-committing stray changes"
        git -C "$PROJECT_PATH" add -A
        git -C "$PROJECT_PATH" commit -m "[nightcrawler] chore: auto-commit stray changes before session" 2>/dev/null || true
        if [[ -n "$(git -C "$PROJECT_PATH" status --porcelain 2>/dev/null)" ]]; then
            die "Worktree still dirty after auto-commit — manual fix needed"
        fi
    fi

    # 9. Session dir already created

    # 10. Session memory
    LEARNINGS_FILE="$SESSION_DIR/learnings.md"

    # 11. Heartbeat
    start_heartbeat

    # 11. Check .claude/ exists for Claude Code CLI
    if [[ ! -d "$PROJECT_PATH/.claude" ]]; then
        log "WARNING: No .claude/ directory in project — Claude Code CLI may not have project context"
    fi

    # 12. Codex connectivity test (retry 3x, degrade if unavailable)
    log "Testing Codex connectivity"
    local codex_test="" codex_rc=1 codex_attempt
    for codex_attempt in 1 2 3; do
        set +e
        codex_test=$(OPENAI_API_KEY="$_OPENAI_KEY" python3 "$SCRIPTS/call_codex.py" --test 2>/dev/null)
        codex_rc=$?
        set -e
        if [[ $codex_rc -eq 0 ]]; then
            break
        fi
        log "RETRY: Codex connectivity test attempt $codex_attempt/3 failed (exit $codex_rc)"
        [[ $codex_attempt -lt 3 ]] && sleep 10
    done

    if [[ $codex_rc -ne 0 ]]; then
        log "WARN: Codex connectivity test failed after 3 attempts — starting in degraded mode"
        CODEX_DEGRADED=true
        escalate_urgent "WARNING ($PROJECT): Codex unreachable at startup — running without auditor"
    else
        local codex_ready
        codex_ready=$(echo "$codex_test" | python3 -c "import sys,json;print(json.load(sys.stdin).get('ready',False))" 2>/dev/null || echo "False")
        if [[ "$codex_ready" != "True" ]]; then
            log "WARN: Codex not ready — starting in degraded mode"
            CODEX_DEGRADED=true
            escalate_urgent "WARNING ($PROJECT): Codex not ready at startup — running without auditor"
        else
            log "Codex ready (primary: $(echo "$codex_test" | python3 -c "import sys,json;print(json.load(sys.stdin).get('primary','unknown'))" 2>/dev/null))"
        fi
    fi

    # 13. Baseline — clean tracked artifacts, check, repair if red, re-check
    cd "$PROJECT_PATH"

    # Remove build artifacts from git tracking (they should be in .gitignore)
    if git ls-files --error-unmatch out/ cache/ 2>/dev/null | head -1 | grep -q .; then
        git rm -r --cached out/ cache/ 2>/dev/null || true
        git commit -m "[nightcrawler] chore: stop tracking build artifacts (out/, cache/)" 2>/dev/null || true
        log "Cleaned tracked build artifacts from git"
    fi

    set +e
    run_timed $BUILD_WALL $BUILD_IDLE $BUILD_CMD
    local baseline_build=$?
    run_timed $TEST_WALL $TEST_IDLE $TEST_CMD
    local baseline_test=$?
    set -e

    if [[ $baseline_build -ne 0 ]] || [[ $baseline_test -ne 0 ]]; then
        log "Baseline red — attempting auto-repair"
        update_status "repairing baseline"
        notify_normal "🩹 Baseline broken — auto-repairing before starting tasks..."

        # Capture the errors for the repair prompt
        local build_errors test_errors
        set +e
        build_errors=$(cd "$PROJECT_PATH" && eval "$BUILD_CMD" 2>&1 | tail -40)
        test_errors=$(cd "$PROJECT_PATH" && eval "$TEST_CMD" 2>&1 | tail -60)
        set -e

        local repair_prompt="The repo has build/test failures. Fix them. Nothing else.

BUILD OUTPUT:
${build_errors}

TEST OUTPUT:
${test_errors}

RULES:
- Fix ONLY the errors shown above. Do not add features, refactor, or change anything else.
- $VERIFY_INSTRUCTIONS
- If a test is fundamentally wrong (tests something that doesn't exist yet), delete that test file.
- Do NOT create new contracts or features. Only fix what's broken."

        local repair_stderr="$SESSION_DIR/claude_repair_stderr.log"
        local repair_output repair_exit
        set +e
        repair_output=$(cd "$PROJECT_PATH" && \
            call_claude "$CLAUDE_CLI_TIMEOUT" "$repair_prompt" \
                --model sonnet \
                --output-format json \
                ${REPAIR_MAX_TURNS:+--max-turns $REPAIR_MAX_TURNS} 2>"$repair_stderr")
        repair_exit=$?
        set -e

        if [[ $repair_exit -ne 0 ]]; then
            log "Repair CLI failed (exit $repair_exit): $(head -5 "$repair_stderr" 2>/dev/null)"
        fi

        record_touched_files
        log_claude_cli_cost "$repair_output" "baseline-repair" "repair"

        # Re-check after repair
        set +e
        run_timed $BUILD_WALL $BUILD_IDLE $BUILD_CMD
        baseline_build=$?
        run_timed $TEST_WALL $TEST_IDLE $TEST_CMD
        baseline_test=$?
        set -e

        if [[ $baseline_build -ne 0 ]] || [[ $baseline_test -ne 0 ]]; then
            die "Baseline still red after repair attempt — manual fix needed"
        fi

        # Repair succeeded — commit the fix
        cd "$PROJECT_PATH"
        git add -A
        git commit -m "[nightcrawler] fix: auto-repair baseline build/test failures

Session: $SESSION_ID"
        local repair_hash=$(git rev-parse HEAD)
        journal '{"event":"baseline_repaired","commit":"'"$repair_hash"'","session":"'"$SESSION_ID"'"}'
        log "Baseline repaired (commit $repair_hash)"
    fi

    BASELINE=$(git rev-parse HEAD)
    log "Baseline: $BASELINE"

    # 14. Budget init — budget.py is telemetry only (real enforcement is prompt-based in bash).
    #     Pass large cap so budget.py's internal check never interferes.
    local budget_ok=false budget_attempt
    for budget_attempt in 1 2 3; do
        if python3 "$SCRIPTS/budget.py" init "$SESSION_ID" 99999 2>/dev/null; then
            budget_ok=true
            break
        fi
        log "RETRY: budget init attempt $budget_attempt/3 failed"
        sleep 2
    done
    if [[ "$budget_ok" != "true" ]]; then
        die "Budget initialization failed after 3 attempts"
    fi
    local budget_label
    if [[ $PROMPT_CAP -gt 0 ]]; then
        budget_label="${PROMPT_CAP} prompts, \$${CODEX_DOLLAR_CAP} Codex"
    else
        budget_label="unlimited (until done), \$${CODEX_DOLLAR_CAP} Codex"
    fi
    log "Budget: $budget_label"

    SESSION_INITIALIZED=true

    # 15. Notify
    local remaining
    remaining=$(count_tasks)
    update_status "running — $remaining tasks remaining"
    notify_normal "🚀 Session $SESSION_ID ($PROJECT)
$remaining tasks | Budget: $budget_label"
    journal '{"event":"session_start","session_id":"'"$SESSION_ID"'","project":"'"$PROJECT"'","prompt_cap":'"$PROMPT_CAP"',"codex_cap":'"$CODEX_DOLLAR_CAP"',"baseline":"'"$BASELINE"'"}'

    # Write active project marker and path (used by dispatcher for live-state detection)
    echo "$PROJECT" > /tmp/nightcrawler-active-project
    # Write project path to tmp (fast) and state dir (persistent across reboots)
    echo "$PROJECT_PATH" > "/tmp/nightcrawler-${PROJECT}-path"
    echo "$PROJECT_PATH" > "$STATE_DIR/project-${PROJECT}-path"
    log "Startup complete"
}

# =============================================================================
# SEC 10: Main loop
# =============================================================================

main_loop() {
    while true; do
        # Pick next task
        TASK_ID=$(pick_next_task)
        if [[ -z "$TASK_ID" ]]; then
            log "No eligible tasks remaining"
            break
        fi

        # Budget gate
        if ! budget_pre_check; then
            log "Prompt cap reached (${PROMPT_COUNT}/${PROMPT_CAP}) — ending session"
            notify_normal "Prompt cap reached (${PROMPT_COUNT}/${PROMPT_CAP}). Ending session."
            break
        fi

        # Kill switch
        if [[ -f "/tmp/nightcrawler-budget-kill" ]]; then
            log "Kill switch active — ending session"
            break
        fi

        log "=== Starting task $TASK_ID ==="
        TASK_COST=0
        local task_start_ts=$SECONDS
        journal '{"event":"task_start","task_id":"'"$TASK_ID"'"}'
        mark_task_in_progress "$TASK_ID"

        # Write task context and extract description for notifications
        local task_file="$SESSION_DIR/tasks/$TASK_ID/task_context.md"
        mkdir -p "$(dirname "$task_file")"
        extract_task_context "$TASK_ID" > "$task_file"
        local task_desc
        task_desc=$(head -1 "$task_file" | sed -E 's/^#{1,6}\s+[A-Z]+-[0-9]+\s+\[.\]\s*//' | head -c 72)

        update_status "working on $TASK_ID: $task_desc"
        notify_normal "🆕 $TASK_ID: $task_desc
Remaining: $(count_tasks) tasks"

        # Phase A: Plan
        if ! plan_loop "$task_file" "$TASK_ID"; then
            if [[ "$PLAN_AUDIT_MODE" == "hard_block" ]]; then
                log "HARD BLOCK: $TASK_ID plan blocked on safety/correctness"
                escalate_urgent "HARD BLOCK ($PROJECT): $TASK_ID plan blocked — safety/correctness concern"
            else
                log "LOCKED: $TASK_ID plan locked"
                escalate_urgent "LOCKED ($PROJECT): $TASK_ID plan failed"
            fi
            sed -i "s/${TASK_ID} \[~\]/${TASK_ID} [ ]/" "$PROJECT_PATH/TASK_QUEUE.md"
            echo "$TASK_ID" >> "$CONTROL_DIR/skip"
            continue
        fi

        # Dry run — stop after plan
        if [[ "$DRY_RUN" == "true" ]]; then
            log "DRY RUN: Plan approved for $TASK_ID"
            notify_normal "Dry run: $TASK_ID plan approved"
            # Reset [~] marker since we're not implementing
            sed -i "s/${TASK_ID} \[~\]/${TASK_ID} [ ]/" "$PROJECT_PATH/TASK_QUEUE.md"
            break
        fi

        # Phase B: Implement
        if ! impl_loop "$PLAN_FILE" "$TASK_ID"; then
            if [[ "$IMPL_REVIEW_MODE" == "hard_block" ]]; then
                log "HARD BLOCK: $TASK_ID impl blocked on safety/correctness"
                escalate_urgent "HARD BLOCK ($PROJECT): $TASK_ID impl blocked — safety/correctness concern"
            else
                log "LOCKED: $TASK_ID implementation failed after 3 soft rejections + local verification failure"
                escalate_urgent "LOCKED ($PROJECT): $TASK_ID impl failed (soft-reject cap + local verify fail)"
            fi
            sed -i "s/${TASK_ID} \[~\]/${TASK_ID} [ ]/" "$PROJECT_PATH/TASK_QUEUE.md"
            echo "$TASK_ID" >> "$CONTROL_DIR/skip"
            revert_owned_files
            continue
        fi

        # Build degraded-approval note if Codex was down or either loop capped out
        local degraded_note=""
        if [[ "$CODEX_DEGRADED" == "true" ]]; then
            degraded_note="DEGRADED MODE: Codex was unavailable — no independent audit/review performed."
        fi
        if [[ "$PLAN_AUDIT_MODE" == "capped_soft_reject" ]] || [[ "$IMPL_REVIEW_MODE" == "capped_soft_reject" ]]; then
            degraded_note="${degraded_note}${degraded_note:+\n}Committed after soft review rejections cap; local verification passed."
            if [[ "$PLAN_AUDIT_MODE" == "capped_soft_reject" ]]; then
                degraded_note="${degraded_note}\nPlan audit last feedback: ${PLAN_LAST_FEEDBACK:0:300}"
            fi
            if [[ "$IMPL_REVIEW_MODE" == "capped_soft_reject" ]]; then
                degraded_note="${degraded_note}\nImpl review last feedback: ${IMPL_LAST_FEEDBACK:0:300}"
            fi
        fi
        if [[ -n "$degraded_note" ]]; then
            log "DEGRADED APPROVAL: $degraded_note"
        fi

        # Phase C: Commit
        notify_normal "✅ $TASK_ID passed review — committing"
        local description="$task_desc"
        local commit_hash
        if ! commit_hash=$(commit_and_close_task "$TASK_ID" "$description" "$degraded_note"); then
            if [[ "$commit_hash" == "GHOST" ]]; then
                log "GHOST COMMIT BLOCKED: $TASK_ID produced no code — locking task"
                escalate_urgent "🚫 GHOST ($PROJECT): $TASK_ID completed pipeline but wrote zero code files"
                echo "$TASK_ID" >> "$CONTROL_DIR/skip"
                continue
            fi
        fi
        log "Committed $TASK_ID as $commit_hash"

        # Post-commit verification
        local revert_count=0
        if ! verify_post_commit "$TASK_ID" "$commit_hash"; then
            revert_count=$((revert_count + 1))
            if ! handle_post_commit_failure "$TASK_ID" "$commit_hash" "$revert_count"; then
                escalate_urgent "LOCKED ($PROJECT): $TASK_ID post-commit verify failed 2x"
                echo "$TASK_ID" >> "$CONTROL_DIR/skip"
                continue
            fi

            # Re-enter Phase B
            log "Re-entering Phase B after revert"
            if ! impl_loop "$PLAN_FILE" "$TASK_ID"; then
                escalate_urgent "LOCKED ($PROJECT): $TASK_ID impl failed after revert"
                echo "$TASK_ID" >> "$CONTROL_DIR/skip"
                continue
            fi

            # Re-commit
            if ! commit_hash=$(commit_and_close_task "$TASK_ID" "$description"); then
                log "GHOST COMMIT BLOCKED on re-commit: $TASK_ID"
                escalate_urgent "🚫 GHOST ($PROJECT): $TASK_ID re-impl produced no code"
                echo "$TASK_ID" >> "$CONTROL_DIR/skip"
                continue
            fi
            if ! verify_post_commit "$TASK_ID" "$commit_hash"; then
                handle_post_commit_failure "$TASK_ID" "$commit_hash" 2
                escalate_urgent "LOCKED ($PROJECT): $TASK_ID post-commit verify failed 2x after re-impl"
                echo "$TASK_ID" >> "$CONTROL_DIR/skip"
                continue
            fi
        fi

        journal '{"event":"task_complete","task_id":"'"$TASK_ID"'","commit":"'"$commit_hash"'","cost":'"$TASK_COST"'}'

        # Capture session memory — 1-line learning from this task (async, non-blocking)
        capture_task_learning "$TASK_ID" "$commit_hash" &

        # Push to nightcrawler/dev after each verified task (disable with NC_AUTO_PUSH=0 in config.sh)
        cd "$PROJECT_PATH"
        if [[ "${NC_AUTO_PUSH:-1}" == "0" ]]; then
            log "Auto-push disabled (NC_AUTO_PUSH=0) — commit stays local"
        elif git push origin HEAD:nightcrawler/dev 2>/dev/null; then
            log "Pushed to nightcrawler/dev"
        else
            log "WARN: push to nightcrawler/dev failed (non-fatal)"
        fi

        local remaining
        remaining=$(count_tasks)
        local prompt_info
        if [[ $PROMPT_CAP -gt 0 ]]; then
            prompt_info="${PROMPT_COUNT}/${PROMPT_CAP}"
        else
            prompt_info="${PROMPT_COUNT}"
        fi
        local elapsed_min=$(( (SECONDS - task_start_ts) / 60 ))
        local notify_msg="✔ $TASK_ID: $task_desc
${elapsed_min}min | \$$TASK_COST | ${prompt_info} prompts | $remaining left"
        if [[ -n "$degraded_note" ]]; then
            notify_msg="${notify_msg}
⚠ Capped soft-reject"
        fi
        notify_normal "$notify_msg"
        update_status "completed $TASK_ID — $remaining remaining"

        log "=== Completed $TASK_ID ==="

        # Prompt cap check for next iteration
        if ! budget_pre_check; then
            log "Prompt cap reached after task (${PROMPT_COUNT}/${PROMPT_CAP}) — ending session"
            break
        fi
    done
}

# =============================================================================
# SEC 11: Session report, end + signals
# =============================================================================

generate_session_report() {
    [[ "$SESSION_INITIALIZED" != "true" ]] && return
    local report="$SESSION_DIR/report.md"
    local journal_file="$SESSION_DIR/journal.jsonl"
    local end_time
    end_time=$(date -u +%FT%TZ)

    cat > "$report" <<HEADER
# Nightcrawler Session Report

**Session:** $SESSION_ID
**Project:** $PROJECT
**Started:** $(head -1 "$journal_file" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('ts','unknown'))" 2>/dev/null || echo "unknown")
**Ended:** $end_time
**Exit:** $(if [[ "$ORDERLY_EXIT" == "true" ]]; then echo "completed"; else echo "aborted"; fi)
**Prompts:** ${PROMPT_COUNT}$(if [[ $PROMPT_CAP -gt 0 ]]; then echo "/${PROMPT_CAP}"; else echo " (unlimited)"; fi) | **API ref cost:** \$${TOTAL_COST} | **Codex:** \$${CODEX_COST}/\$${CODEX_DOLLAR_CAP}$(if [[ "$CODEX_DEGRADED" == "true" ]]; then echo " (degraded)"; fi)
**Baseline:** ${BASELINE:-unknown}

---

## Tasks
HEADER

    # Parse journal for task events
    if [[ -f "$journal_file" ]]; then
        python3 -c "
import json, sys

journal_path = '$journal_file'
tasks = {}
events = []

with open(journal_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except:
            continue
        events.append(e)
        tid = e.get('task_id', '')
        ev = e.get('event', '')
        if tid and ev:
            if tid not in tasks:
                tasks[tid] = {'events': [], 'cost': 0, 'commit': '', 'verdict_history': [], 'degraded': False}
            tasks[tid]['events'].append(ev)
            if ev == 'task_complete':
                tasks[tid]['cost'] = e.get('cost', 0)
                tasks[tid]['commit'] = e.get('commit', '')[:8]
            if ev in ('plan_capped_soft_reject', 'impl_capped_soft_reject'):
                tasks[tid]['degraded'] = True
                tasks[tid]['last_feedback'] = e.get('last_feedback', '')
            if ev == 'plan_hard_block':
                tasks[tid]['hard_block'] = 'plan'
            if ev == 'impl_hard_block':
                tasks[tid]['hard_block'] = 'impl'
            if ev in ('plan_audited', 'impl_reviewed'):
                tasks[tid]['verdict_history'].append(e.get('verdict', ''))

if not tasks:
    print('\nNo tasks were attempted this session.')
else:
    for tid, info in tasks.items():
        evts = info['events']
        status = '?'
        if 'task_complete' in evts:
            status = 'COMPLETED'
        elif info.get('hard_block'):
            status = f\"HARD BLOCK ({info['hard_block']})\"
        elif 'session_aborted' in [e.get('event') for e in events]:
            status = 'ABORTED (session ended)'
        elif any('locked' in e.lower() for e in evts):
            status = 'LOCKED'
        else:
            status = 'INCOMPLETE'

        line = f\"### {tid} — {status}\"
        if info['commit']:
            line += f\" (commit: \`{info['commit']}\`)\"
        print(line)

        if info['cost']:
            print(f\"- Cost: \${info['cost']}\")

        verdicts = info['verdict_history']
        if verdicts:
            print(f\"- Review history: {' → '.join(verdicts)}\")

        if info['degraded']:
            print(f\"- ⚠ DEGRADED APPROVAL: Proceeded after 3 soft rejections; local verification passed.\")
            fb = info.get('last_feedback', '')
            if fb:
                print(f\"- Last reviewer feedback: {fb[:500]}\")

        if info.get('hard_block'):
            print(f\"- BLOCKED on safety/correctness concern\")

        print()
" 2>/dev/null >> "$report"
    fi

    # Recovery info
    if [[ "$RECOVERY_NEEDED" == "true" ]]; then
        cat >> "$report" <<RECOVERY

## Recovery
- Previous session: $RECOVERY_SESSION_ID
- Last event: $RECOVERY_LAST_EVENT
- Task: $RECOVERY_TASK_ID
- Commit: ${RECOVERY_COMMIT:-none}
RECOVERY
    fi

    # Mateo's notes
    local notes_file="$CONTROL_DIR/notes"
    if [[ -f "$notes_file" ]] && [[ -s "$notes_file" ]]; then
        echo "" >> "$report"
        echo "## Mateo's Notes" >> "$report"
        echo '```' >> "$report"
        cat "$notes_file" >> "$report"
        echo '```' >> "$report"
    fi

    # Git log of session commits
    if [[ -n "${BASELINE:-}" ]]; then
        local session_commits
        session_commits=$(git -C "$PROJECT_PATH" log --oneline "${BASELINE}..HEAD" 2>/dev/null || echo "none")
        if [[ -n "$session_commits" ]] && [[ "$session_commits" != "none" ]]; then
            echo "" >> "$report"
            echo "## Commits This Session" >> "$report"
            echo '```' >> "$report"
            echo "$session_commits" >> "$report"
            echo '```' >> "$report"
        fi
    fi

    echo "" >> "$report"
    echo "---" >> "$report"
    echo "*Generated at $end_time*" >> "$report"

    log "Session report written to $report"
}

session_end() {
    [[ "$SESSION_ENDING" == "true" ]] && return
    SESSION_ENDING=true
    local reason="${1:-unknown}"

    if [[ "$SESSION_INITIALIZED" == "true" ]]; then
        local branch
        branch=$(git -C "$PROJECT_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        if [[ "$branch" == "nightcrawler/dev" ]]; then
            revert_owned_files
        fi
    fi

    if [[ "$SESSION_INITIALIZED" == "true" ]] && [[ "$ORDERLY_EXIT" != "true" ]]; then
        journal '{"event":"session_aborted","reason":"'"$reason"'","ts":"'"$(date -u +%FT%TZ)"'"}'
    fi

    generate_session_report

    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] && [[ "$SESSION_INITIALIZED" == "true" ]]; then
        # Count completed/locked tasks from journal
        local tasks_done=0 tasks_locked=0
        local journal_file="$SESSION_DIR/journal.jsonl"
        if [[ -f "$journal_file" ]]; then
            tasks_done=$(grep -c '"event":"task_complete"' "$journal_file" 2>/dev/null) || true
            tasks_locked=$(grep -cE '"event":"(plan_hard_block|impl_hard_block)"' "$journal_file" 2>/dev/null) || true
        fi

        local prompt_label
        if [[ $PROMPT_CAP -gt 0 ]]; then
            prompt_label="${PROMPT_COUNT}/${PROMPT_CAP} prompts"
        else
            prompt_label="${PROMPT_COUNT} prompts (unlimited)"
        fi

        local degraded_label=""
        if [[ "$CODEX_DEGRADED" == "true" ]]; then
            degraded_label=" | Codex: degraded"
        fi

        local end_status
        if [[ "$ORDERLY_EXIT" == "true" ]]; then
            end_status="completed"
        else
            end_status="aborted: $reason"
        fi

        notify_normal "🏁 Session $end_status
${tasks_done} done, ${tasks_locked} locked
${prompt_label} | Cost: \$${TOTAL_COST} | Codex: \$${CODEX_COST}${degraded_label}"
    fi

    [[ "$HEARTBEAT_STARTED" == "true" ]] && stop_heartbeat
    rm -f "/tmp/nightcrawler-${PROJECT}-status" 2>/dev/null || true
    rm -f /tmp/nightcrawler-active-project 2>/dev/null || true
    # Do NOT rm -rf CONTROL_DIR — manifest must survive for next session's recovery
}

trap 'session_end "signal"' INT TERM
trap 'session_end "exit"' EXIT

# =============================================================================
# Main
# =============================================================================

main() {
    startup
    main_loop
    ORDERLY_EXIT=true
    journal '{"event":"session_complete","ts":"'"$(date -u +%FT%TZ)"'","prompts":'"$PROMPT_COUNT"',"prompt_cap":'"$PROMPT_CAP"',"codex_cost":'"$CODEX_COST"'}'
    session_end "completed"
}

main
