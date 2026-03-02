#!/usr/bin/env bash
# nightcrawler.sh — Deterministic bash orchestrator for autonomous task execution.
#
# Usage: nightcrawler.sh <project> [--budget N] [--dry-run]
#
# LLMs are only called for creative work (planning, coding, reviewing).
# All routing, sequencing, and error handling is deterministic bash.

set -euo pipefail

# =============================================================================
# SEC 1: Environment + constants
# =============================================================================

PROJECT="${1:?Usage: nightcrawler.sh <project> [--budget N] [--dry-run]}"
shift

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${NIGHTCRAWLER_STATE_PATH:-/home/nightcrawler/nightcrawler}"
PROJECT_PATH="${NIGHTCRAWLER_PROJECT_PATH:-/home/nightcrawler/projects/$PROJECT}"
CONTROL_DIR="/tmp/nightcrawler/${PROJECT}"
SESSION_ID="$(date -u +%Y%m%d-%H%M%S)-${PROJECT}"
SESSION_DIR="$STATE_DIR/sessions/$SESSION_ID"
mkdir -p "$SESSION_DIR"
LOCKFILE="/tmp/nightcrawler-${PROJECT}.lock"
TOUCHED_FILES="$CONTROL_DIR/touched_files"

BUDGET_CAP=20
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --budget) BUDGET_CAP="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Timeouts (seconds)
PLAN_WALL=300   PLAN_IDLE=120
AUDIT_WALL=180  AUDIT_IDLE=60
IMPL_WALL=600   IMPL_IDLE=180
REVIEW_WALL=180 REVIEW_IDLE=60
FORGE_BUILD_WALL=120 FORGE_BUILD_IDLE=60
FORGE_TEST_WALL=300  FORGE_TEST_IDLE=120
CODEX_CALL_TIMEOUT=180  # wall-clock safety net for Codex (has internal timeouts)
CLAUDE_CLI_TIMEOUT=1200 # wall-clock safety net for Claude Code CLI (no idle — JSON mode has no output)

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

# =============================================================================
# SEC 3: Helpers
# =============================================================================

log() { local msg="[$(date -u +%FT%TZ)] $*"; echo "$msg" >> "$SESSION_DIR/nightcrawler.log" 2>/dev/null; echo "$msg" >&2; }

run_timed() {
    local wall="$1" idle="$2"; shift 2
    python3 "$SCRIPTS/run_with_timeout.py" "$wall" "$idle" "$@"
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

notify_normal() {
    local msg="$1"
    [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] && return 0
    [[ -z "${TELEGRAM_CHAT_ID:-}" ]] && return 0
    local escaped
    escaped=$(html_escape "$msg")
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d parse_mode=HTML \
        -d text="$escaped" >/dev/null 2>&1 || true
}

escalate_urgent() {
    local msg="$1"
    [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] && return 0
    [[ -z "${TELEGRAM_CHAT_ID:-}" ]] && return 0
    local escaped
    escaped=$(html_escape "$msg")
    local attempt
    for attempt in 1 2 3; do
        if curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="$TELEGRAM_CHAT_ID" \
            -d parse_mode=HTML \
            -d text="$escaped" >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done
}

die() {
    log "FATAL: $*"
    escalate_urgent "FATAL ($PROJECT): $*"
    exit 1
}

budget_check() {
    python3 "$SCRIPTS/budget.py" check "$SESSION_ID" 2>/dev/null || echo '{"can_continue": false}'
}

budget_pre_check() {
    local check
    check=$(budget_check)
    local can
    can=$(echo "$check" | python3 -c "import sys,json;print(json.load(sys.stdin).get('can_continue',False))" 2>/dev/null || echo "False")
    if [[ "$can" != "True" ]]; then
        log "Budget exhausted"
        return 1
    fi
    return 0
}

log_claude_cli_cost() {
    local raw_output="$1" task_id="$2" phase="$3"
    local cost_info
    cost_info=$(echo "$raw_output" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    cost = data.get('total_cost_usd', data.get('cost_usd', data.get('cost', 0)))
    usage = data.get('usage', {})
    # Claude CLI splits input across cached/non-cached — sum all three
    inp = usage.get('input_tokens', 0) \
        + usage.get('cache_creation_input_tokens', 0) \
        + usage.get('cache_read_input_tokens', 0)
    out = usage.get('output_tokens', 0)
    model = list(data.get('modelUsage', {}).keys())[0] if data.get('modelUsage') else data.get('model', 'unknown')
    print(json.dumps({'cost_usd': cost, 'input_tokens': inp, 'output_tokens': out, 'model': model}))
except:
    print(json.dumps({'cost_usd': 0, 'input_tokens': 0, 'output_tokens': 0, 'model': 'unknown'}))
" 2>/dev/null)

    local cost
    cost=$(echo "$cost_info" | python3 -c "import sys,json;print(json.load(sys.stdin).get('cost_usd',0))" 2>/dev/null || echo "0")

    if [[ "$cost" != "0" ]]; then
        python3 "$SCRIPTS/budget.py" log "$SESSION_ID" "$cost_info" >/dev/null 2>&1 || true
        TASK_COST=$(python3 -c "print(round($TASK_COST + $cost, 6))" 2>/dev/null || echo "$TASK_COST")
        TOTAL_COST=$(python3 -c "print(round($TOTAL_COST + $cost, 6))" 2>/dev/null || echo "$TOTAL_COST")
    fi
}

log_codex_cost() {
    local raw_output="$1"
    local cost
    cost=$(echo "$raw_output" | python3 -c "import sys,json;print(json.load(sys.stdin).get('cost_usd',0))" 2>/dev/null || echo "0")
    if [[ "$cost" != "0" ]]; then
        python3 "$SCRIPTS/budget.py" log "$SESSION_ID" "$raw_output" >/dev/null 2>&1 || true
        TASK_COST=$(python3 -c "print(round($TASK_COST + $cost, 6))" 2>/dev/null || echo "$TASK_COST")
        TOTAL_COST=$(python3 -c "print(round($TOTAL_COST + $cost, 6))" 2>/dev/null || echo "$TOTAL_COST")
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
    cd "$PROJECT_PATH"
    local violations=0

    # Check tracked changes
    while IFS= read -r -d '' f; do
        case "$f" in
            src/*|lib/*|test/*|script/*) ;;  # expected
            TASK_QUEUE.md|PROGRESS.md|SESSION_PROGRESS.md|memory.md) ;;  # expected
            foundry.toml|remappings.txt) ;;  # expected config
            *)
                log "SCOPE: Unexpected tracked change: $f"
                git checkout HEAD -- "$f" 2>/dev/null || true
                violations=$((violations + 1))
                ;;
        esac
    done < <(git diff --name-only -z HEAD -- 2>/dev/null)

    # Check untracked files
    while IFS= read -r -d '' f; do
        case "$f" in
            src/*|lib/*|test/*|script/*) ;;
            *)
                log "SCOPE: Unexpected untracked file: $f"
                case "$f" in ..|../*|/*|"") continue ;; esac
                rm -rf -- "$f" 2>/dev/null || true
                violations=$((violations + 1))
                ;;
        esac
    done < <(git ls-files --others --exclude-standard -z)

    if [[ $violations -gt 0 ]]; then
        log "SCOPE: Cleaned $violations violations"
        return 1
    fi
    return 0
}

# =============================================================================
# SEC 4: Task queue
# =============================================================================

pick_next_task() {
    local queue="$PROJECT_PATH/TASK_QUEUE.md"
    [[ -f "$queue" ]] || { echo ""; return; }

    # Check skip list
    local skip_file="$CONTROL_DIR/skip"

    python3 -c "
import re, sys

queue_path = '$queue'
skip_path = '$skip_file'

skips = set()
try:
    with open(skip_path) as f:
        skips = {l.strip() for l in f if l.strip()}
except FileNotFoundError:
    pass

with open(queue_path) as f:
    content = f.read()
    lines = content.splitlines()

# Collect all task lines and their full blocks for dependency parsing
# Format: #### NC-XXX [x] Title  OR  #### NC-XXX [ ] Title
# Dependencies appear in later lines as '- **Dependencies:** NC-001, NC-002'
task_header_re = re.compile(r'^#{1,6}\s+(NC-\d+)\s+\[(.)\]')
dep_line_re = re.compile(r'^\-\s+\*\*Dependencies?:\*\*\s*(.*)', re.IGNORECASE)

# First pass: find all done task IDs
done_ids = set()
for line in lines:
    m = task_header_re.match(line)
    if m and m.group(2) == 'x':
        done_ids.add(m.group(1))

# Second pass: find first eligible [ ] task
current_task = None
current_task_line = None
for line in lines:
    m = task_header_re.match(line)
    if m:
        if current_task:
            # Previous task had no deps line — eligible if not skipped/manual
            print(current_task)
            sys.exit(0)
        if m.group(2) == ' ':
            tid = m.group(1)
            if tid not in skips and 'MANUAL' not in line:
                current_task = tid
                current_task_line = line
            else:
                current_task = None
        else:
            current_task = None
        continue

    if current_task:
        dm = dep_line_re.match(line.strip())
        if dm:
            dep_str = dm.group(1).strip()
            if dep_str.lower() == 'none' or not dep_str:
                print(current_task)
                sys.exit(0)
            deps = [d.strip() for d in dep_str.split(',') if d.strip()]
            if all(d in done_ids for d in deps):
                print(current_task)
                sys.exit(0)
            else:
                current_task = None

# Last task in file with no deps line
if current_task:
    print(current_task)
    sys.exit(0)

print('')
" 2>/dev/null
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
    sed -i "s/${task_id} \[ \]/${task_id} [x]/" "$queue"
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
    grep -cE '^#{1,6}\s+NC-\d+\s+\[ \]' "$queue" 2>/dev/null || echo "0"
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
    local prompt="You are planning a task for a Solidity/Foundry project.

TASK:
${task_content}

RULES:
${rules}

Instructions:
- Read RESEARCH.md to understand the canonical struct definitions, state machine, and protocol spec.
- Read any existing source files in src/ and test/ to understand what's already built.
- Output a detailed implementation plan in markdown format as your final response.
- The plan must include: files to create/modify, structs/enums (matching RESEARCH.md exactly), functions with signatures, events, test cases.
- Do NOT implement the code — only plan.
- Do NOT create or modify any source files.
"

    log "Planning $task_id"
    update_status "planning $task_id"

    local raw_output exit_code
    local claude_stderr="$SESSION_DIR/claude_plan_${task_id}_stderr.log"
    set +e
    raw_output=$(cd "$PROJECT_PATH" && timeout "$CLAUDE_CLI_TIMEOUT" \
        claude -p "$prompt" \
            --model sonnet \
            --output-format json \
            --max-turns 10 2>"$claude_stderr")
    exit_code=$?
    set -e

    log_claude_cli_cost "$raw_output" "$task_id" "planning"

    if [[ $exit_code -ne 0 ]]; then
        log "Plan command failed (exit $exit_code). stderr: $(head -5 "$claude_stderr" 2>/dev/null)"
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

RULES:
${rules}

Instructions:
- Read RESEARCH.md to verify struct definitions and protocol spec.
- Address EVERY point in the auditor's feedback.
- Output the complete revised plan in markdown format as your final response.
- Do NOT implement the code — only revise the plan.
- Do NOT create or modify any source files.
"

    log "Revising plan (iteration $iteration)"
    local raw_output exit_code
    local claude_stderr="$SESSION_DIR/claude_planrev_${task_id}_${iteration}_stderr.log"
    set +e
    raw_output=$(cd "$PROJECT_PATH" && timeout "$CLAUDE_CLI_TIMEOUT" \
        claude -p "$prompt" \
            --model sonnet \
            --output-format json \
            --max-turns 10 2>"$claude_stderr")
    exit_code=$?
    set -e

    log_claude_cli_cost "$raw_output" "$task_id" "plan-revision"

    if [[ $exit_code -ne 0 ]]; then
        log "Plan revision failed (exit $exit_code). stderr: $(head -5 "$claude_stderr" 2>/dev/null)"
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
    raw_output=$(timeout "$CODEX_CALL_TIMEOUT" \
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
    set +e
    AUDIT_RAW=$(audit_plan_call "$plan_file" "$task_file")
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        die "Audit infrastructure failure (exit $rc) — Codex unavailable, stopping session"
    fi
    AUDIT_VERDICT=$(echo "$AUDIT_RAW" | python3 -c "import sys,json;print(json.load(sys.stdin).get('verdict','REJECTED'))")
    AUDIT_FEEDBACK=$(echo "$AUDIT_RAW" | python3 -c "import sys,json;print(json.load(sys.stdin).get('feedback',''))")
}

# Classify a review/audit rejection as hard_block or soft_reject.
# Hard blocks are issues where proceeding risks correctness or safety.
# Everything else is a soft reject (style, naming, minor structure).
# Returns via global CLASSIFY_RESULT: approved | hard_block | soft_reject
HARD_BLOCK_PATTERNS="security.vulnerabilit|data.loss|reentrancy|overflow|underflow|privilege.escalation|funds.at.risk|loss.of.funds|critical.vulnerabilit"

classify_rejection() {
    local feedback="$1"
    local lower
    lower=$(echo "$feedback" | tr '[:upper:]' '[:lower:]')

    if echo "$lower" | grep -qEi "$HARD_BLOCK_PATTERNS"; then
        CLASSIFY_RESULT="hard_block"
    else
        CLASSIFY_RESULT="soft_reject"
    fi
}

plan_loop() {
    local task_file="$1" task_id="$2"
    local plan_file iteration=0
    local -a feedbacks=()
    PLAN_AUDIT_MODE="approved"

    plan_file=$(plan_task "$task_file" "$task_id") || return 1
    [[ -z "$plan_file" ]] && return 1

    while (( iteration < 3 )); do
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

        if (( iteration < 3 )); then
            if ! revise_plan "$plan_file" "$AUDIT_FEEDBACK" "$iteration" "$task_id"; then
                log "Plan revision failed"
                feedbacks+=("Plan revision command failed")
            fi
        fi
    done

    # 3 soft rejections exhausted — proceed with warning
    log "plan_loop: 3 soft rejections exhausted — proceeding with capped plan"
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

    prompt="You are implementing a task for a Solidity/Foundry project.

PLAN:
${plan}

RULES:
${rules}

Instructions:
- Implement exactly what the plan says. No more, no less.
- Write clean, tested Solidity code.
- Run 'forge build' and 'forge test' to verify.
- Do NOT modify files outside the plan's scope.
- Do NOT create probe/test contracts.
"

    log "Implementing $task_id"
    update_status "implementing $task_id"

    # Use timeout (not run_timed) — Claude Code CLI in JSON mode produces no
    # intermediate output, so idle timeout would kill it prematurely.
    # cd into project dir instead of --cwd (not supported on all CLI versions).
    local raw_output exit_code
    local claude_stderr="$SESSION_DIR/claude_impl_${task_id}_stderr.log"
    set +e
    raw_output=$(cd "$project_path" && timeout "$CLAUDE_CLI_TIMEOUT" \
        claude -p "$prompt" \
            --model sonnet \
            --output-format json \
            --max-turns 25 2>"$claude_stderr")
    exit_code=$?
    set -e

    if [[ $exit_code -ne 0 ]]; then
        log "Claude CLI exited $exit_code. stderr: $(head -5 "$claude_stderr" 2>/dev/null)"
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

    prompt="You are revising an implementation that was rejected by the code reviewer.

PLAN:
${plan}

REVIEWER FEEDBACK (iteration $iteration):
${feedback}

RULES:
${rules}

Instructions:
- Address EVERY point in the reviewer's feedback.
- Run 'forge build' and 'forge test' to verify your changes.
- Do NOT modify files outside the plan's scope.
"

    log "Revising implementation (iteration $iteration)"
    update_status "revising $TASK_ID (iteration $iteration)"

    # Use timeout (not run_timed) — same reason as implement_task
    local raw_output exit_code
    local claude_stderr="$SESSION_DIR/claude_rev_${TASK_ID}_${iteration}_stderr.log"
    set +e
    raw_output=$(cd "$PROJECT_PATH" && timeout "$CLAUDE_CLI_TIMEOUT" \
        claude -p "$prompt" \
            --model sonnet \
            --output-format json \
            --max-turns 25 2>"$claude_stderr")
    exit_code=$?
    set -e

    if [[ $exit_code -ne 0 ]]; then
        log "Claude CLI exited $exit_code. stderr: $(head -5 "$claude_stderr" 2>/dev/null)"
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
    raw_output=$(timeout "$CODEX_CALL_TIMEOUT" \
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
    set +e
    REVIEW_RAW=$(review_impl "$plan_file")
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        die "Review infrastructure failure (exit $rc) — Codex unavailable, stopping session"
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
    IMPL_REVIEW_MODE="approved"
    REVIEW_FEEDBACK=""

    while (( iteration < 3 )); do
        iteration=$((iteration + 1))

        if [[ $iteration -eq 1 ]]; then
            if ! implement_task "$plan_file" "$PROJECT_PATH" "$task_id"; then
                log "Implementation failed"
                feedbacks+=("Implementation command failed")
                continue
            fi
        else
            if ! revise_impl "$plan_file" "${feedbacks[-1]}" "$iteration"; then
                log "Revision failed"
                feedbacks+=("Revision command failed")
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
            continue
        fi

        # APPROVED — check scope before accepting
        if ! verify_impl_scope; then
            log "Scope violations cleaned — re-testing and re-reviewing"

            set +e
            run_timed $FORGE_BUILD_WALL $FORGE_BUILD_IDLE forge build
            local build_ok=$?
            run_timed $FORGE_TEST_WALL $FORGE_TEST_IDLE forge test -v
            local test_ok=$?
            set -e

            if [[ $build_ok -ne 0 ]] || [[ $test_ok -ne 0 ]]; then
                feedbacks+=("Scope cleanup broke build/tests")
                continue
            fi

            run_review "$plan_file"

            if [[ "$REVIEW_VERDICT" != "APPROVED" ]]; then
                feedbacks+=("Post-scope-cleanup re-review: $REVIEW_FEEDBACK")
                continue
            fi
        fi

        IMPL_REVIEW_MODE="approved"
        journal '{"event":"impl_approved","task_id":"'"$task_id"'"}'
        return 0
    done

    # 3 iterations exhausted — distinguish implementation failures from soft rejections
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
    run_timed $FORGE_BUILD_WALL $FORGE_BUILD_IDLE forge build
    local cap_build=$?
    run_timed $FORGE_TEST_WALL $FORGE_TEST_IDLE forge test -v
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

    local commit_msg="[nightcrawler] feat($task_id): $description

Task: $task_id
Session: $SESSION_ID
Cost: \$${TASK_COST}"
    if [[ -n "$degraded_note" ]]; then
        commit_msg="${commit_msg}
Note: $(echo -e "$degraded_note" | head -1)"
    fi

    git commit -m "$commit_msg"
    local hash
    hash=$(git rev-parse HEAD)
    journal '{"event":"task_committed","task_id":"'"$task_id"'","commit":"'"$hash"'","ts":"'"$(date -u +%FT%TZ)"'"}'
    echo "$hash"
}

verify_post_commit() {
    local task_id="$1" commit_hash="$2"
    cd "$PROJECT_PATH"

    set +e
    run_timed $FORGE_BUILD_WALL $FORGE_BUILD_IDLE forge build
    local b=$?
    run_timed $FORGE_TEST_WALL $FORGE_TEST_IDLE forge test -v
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
                run_timed $FORGE_BUILD_WALL $FORGE_BUILD_IDLE forge build
                local b=$?
                run_timed $FORGE_TEST_WALL $FORGE_TEST_IDLE forge test
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
    local current
    current=$(git -C "$PROJECT_PATH" rev-parse --abbrev-ref HEAD)

    case "$current" in
        "main")
            if git -C "$PROJECT_PATH" rev-parse --verify nightcrawler/dev &>/dev/null; then
                log "On main — switching to existing nightcrawler/dev"
                git -C "$PROJECT_PATH" checkout nightcrawler/dev
            else
                log "First session — creating nightcrawler/dev from main"
                git -C "$PROJECT_PATH" checkout -B nightcrawler/dev main
            fi
            ;;
        "nightcrawler/dev")
            log "Already on nightcrawler/dev"
            ;;
        *)
            die "On unexpected branch '$current' — expected main or nightcrawler/dev"
            ;;
    esac
}

sync_with_main() {
    log "Syncing nightcrawler/dev with main"
    if ! git -C "$PROJECT_PATH" merge main --no-edit 2>/dev/null; then
        git -C "$PROJECT_PATH" merge --abort 2>/dev/null || true
        die "Cannot merge main into nightcrawler/dev (conflict) — manual reconciliation needed"
    fi
    log "nightcrawler/dev synced with main"
}

startup() {
    # 1. flock
    exec 200>"$LOCKFILE"
    flock -n 200 || die "Another session running (lock held on $LOCKFILE)"
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

    # 8. Check clean worktree
    if [[ -n "$(git -C "$PROJECT_PATH" status --porcelain 2>/dev/null)" ]]; then
        die "Worktree unexpectedly dirty after recovery and sync"
    fi

    # 9. Session dir already created

    # 10. Heartbeat
    start_heartbeat

    # 11. Check .claude/ exists for Claude Code CLI
    if [[ ! -d "$PROJECT_PATH/.claude" ]]; then
        log "WARNING: No .claude/ directory in project — Claude Code CLI may not have project context"
    fi

    # 12. Codex connectivity test
    log "Testing Codex connectivity"
    set +e
    local codex_test
    codex_test=$(python3 "$SCRIPTS/call_codex.py" --test 2>/dev/null)
    local codex_rc=$?
    set -e
    if [[ $codex_rc -ne 0 ]]; then
        die "Codex connectivity test failed — cannot proceed without auditor"
    fi
    local codex_ready
    codex_ready=$(echo "$codex_test" | python3 -c "import sys,json;print(json.load(sys.stdin).get('ready',False))" 2>/dev/null || echo "False")
    if [[ "$codex_ready" != "True" ]]; then
        die "Codex not ready — cannot proceed without auditor"
    fi
    log "Codex ready (primary: $(echo "$codex_test" | python3 -c "import sys,json;print(json.load(sys.stdin).get('primary','unknown'))" 2>/dev/null))"

    # 13. Baseline
    cd "$PROJECT_PATH"
    set +e
    run_timed $FORGE_BUILD_WALL $FORGE_BUILD_IDLE forge build
    local baseline_build=$?
    run_timed $FORGE_TEST_WALL $FORGE_TEST_IDLE forge test
    local baseline_test=$?
    set -e
    if [[ $baseline_build -ne 0 ]] || [[ $baseline_test -ne 0 ]]; then
        die "Baseline build/test failed — repo is red, cannot proceed"
    fi
    BASELINE=$(git rev-parse HEAD)
    log "Baseline: $BASELINE"

    # 14. Budget init
    python3 "$SCRIPTS/budget.py" init "$SESSION_ID" "$BUDGET_CAP" 2>/dev/null || \
        die "Budget initialization failed"

    SESSION_INITIALIZED=true

    # 15. Notify
    local remaining
    remaining=$(count_tasks)
    update_status "running — $remaining tasks remaining"
    notify_normal "Session $SESSION_ID started. $remaining tasks. Budget: \$$BUDGET_CAP."
    journal '{"event":"session_start","session_id":"'"$SESSION_ID"'","project":"'"$PROJECT"'","budget":'"$BUDGET_CAP"',"baseline":"'"$BASELINE"'"}'
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
            log "Budget exhausted — ending session"
            notify_normal "Budget exhausted. Ending session."
            break
        fi

        # Kill switch
        if [[ -f "/tmp/nightcrawler-budget-kill" ]]; then
            log "Kill switch active — ending session"
            break
        fi

        log "=== Starting task $TASK_ID ==="
        TASK_COST=0
        journal '{"event":"task_start","task_id":"'"$TASK_ID"'"}'
        mark_task_in_progress "$TASK_ID"
        update_status "working on $TASK_ID"

        # Write task context
        local task_file="$SESSION_DIR/tasks/$TASK_ID/task_context.md"
        mkdir -p "$(dirname "$task_file")"
        extract_task_context "$TASK_ID" > "$task_file"

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

        # Build degraded-approval note if either loop capped out
        local degraded_note=""
        if [[ "$PLAN_AUDIT_MODE" == "capped_soft_reject" ]] || [[ "$IMPL_REVIEW_MODE" == "capped_soft_reject" ]]; then
            degraded_note="Committed after 3 soft review rejections; local verification passed."
            if [[ "$PLAN_AUDIT_MODE" == "capped_soft_reject" ]]; then
                degraded_note="${degraded_note}\nPlan audit last feedback: ${PLAN_LAST_FEEDBACK:0:300}"
            fi
            if [[ "$IMPL_REVIEW_MODE" == "capped_soft_reject" ]]; then
                degraded_note="${degraded_note}\nImpl review last feedback: ${IMPL_LAST_FEEDBACK:0:300}"
            fi
            log "DEGRADED APPROVAL: $degraded_note"
        fi

        # Phase C: Commit
        local description
        description=$(head -1 "$task_file" | sed 's/^- \[.\] \*\*[^*]*\*\* *//' | head -c 72)
        local commit_hash
        commit_hash=$(commit_and_close_task "$TASK_ID" "$description" "$degraded_note")
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
            commit_hash=$(commit_and_close_task "$TASK_ID" "$description")
            if ! verify_post_commit "$TASK_ID" "$commit_hash"; then
                handle_post_commit_failure "$TASK_ID" "$commit_hash" 2
                escalate_urgent "LOCKED ($PROJECT): $TASK_ID post-commit verify failed 2x after re-impl"
                echo "$TASK_ID" >> "$CONTROL_DIR/skip"
                continue
            fi
        fi

        journal '{"event":"task_complete","task_id":"'"$TASK_ID"'","commit":"'"$commit_hash"'","cost":'"$TASK_COST"'}'
        local remaining
        remaining=$(count_tasks)
        local notify_msg="Done: $TASK_ID ($commit_hash). Remaining: $remaining. Spent: \$$TASK_COST."
        if [[ -n "$degraded_note" ]]; then
            notify_msg="${notify_msg} ⚠ Capped soft-reject."
        fi
        notify_normal "$notify_msg"
        update_status "completed $TASK_ID — $remaining remaining"

        log "=== Completed $TASK_ID ==="

        # Budget check for next iteration
        if ! budget_pre_check; then
            log "Budget exhausted after task — ending session"
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
**Budget:** \$$BUDGET_CAP (spent: \$$TOTAL_COST)
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
        if [[ "$ORDERLY_EXIT" == "true" ]]; then
            notify_normal "Session $SESSION_ID completed. Total cost: \$$TOTAL_COST."
        else
            notify_normal "Session $SESSION_ID aborted: $reason. Cost so far: \$$TOTAL_COST."
        fi
    fi

    [[ "$HEARTBEAT_STARTED" == "true" ]] && stop_heartbeat
    rm -f "/tmp/nightcrawler-${PROJECT}-status" 2>/dev/null || true
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
    journal '{"event":"session_complete","ts":"'"$(date -u +%FT%TZ)"'","total_cost":'"$TOTAL_COST"'}'
    session_end "completed"
}

main
