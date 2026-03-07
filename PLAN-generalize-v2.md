# Plan: Nightcrawler Generalization v2

## Context

v1 (PLAN-generalize.md) is implemented on `nightcrawler/generalize`: config-driven `start.sh`, `nightcrawler-init.sh` CLI, `generate-workspace.sh`. This plan covers the next layer: Telegram threads per project, multi-stack detection, and quality-of-life improvements.

**Branch:** `nightcrawler/generalize` (continues from v1)

---

## Phase 1: Telegram Threads Per Project

### Problem
All Nightcrawler notifications go to one flat Telegram chat. With multiple projects, messages from clout and my-api interleave. The screenshot from Hivemind shows the UX we want: Telegram Topics (forum threads), one thread per project.

### How Telegram Topics Work
- A Telegram group with "Topics" enabled assigns each topic a numeric `message_thread_id`
- The Bot API `sendMessage` accepts an optional `message_thread_id` parameter
- Messages sent with a thread ID appear inside that topic; without it, they go to "General"
- Topics are created manually in Telegram (or via `createForumTopic` Bot API)

### Design

**New config var per project:** `TELEGRAM_THREAD_ID`
- Set in `.nightcrawler/config.sh` (e.g., `TELEGRAM_THREAD_ID=12345`)
- If empty/unset, messages go to the default chat (backward compatible)
- The init CLI prompts: "Telegram thread ID (optional, leave blank for default chat):"

**Changes to `nightcrawler.sh`:**

Both `notify_normal()` and `escalate_urgent()` currently call:
```bash
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    -d parse_mode=HTML \
    -d text="$escaped"
```

After:
```bash
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
    # Check Telegram API success
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
```

**Changes to `start.sh`:**
- Section 4 already declares config vars before sourcing — add `TELEGRAM_THREAD_ID=""` to the list
- Export it so `nightcrawler.sh` (launched via nohup) inherits it:
  ```bash
  [[ -n "$TELEGRAM_THREAD_ID" ]] && export TELEGRAM_THREAD_ID
  ```

**Changes to `nightcrawler-init.sh`:**
- Add prompt: `Telegram thread ID (optional):` after the tools prompt
- Write `TELEGRAM_THREAD_ID="$value"` to config.sh
- validate_cmd not needed (it's a numeric ID, validate with `[[ "$val" =~ ^[0-9]*$ ]]`)

**Changes to `config/openclaw.yaml`:**
- Add `telegram_thread_id` field per project (informational, scripts read from config.sh):
  ```yaml
  projects:
    clout:
      path: /home/nightcrawler/projects/clout
      base_branch: main
      telegram_thread_id: 12345
  ```

**Setup steps (manual, one-time):**
1. Enable Topics in the Nightcrawler Telegram group (Group Settings > Topics)
2. Create a topic per project (e.g., "clout", "my-api")
3. Get the thread ID: send a message in the topic, use `getUpdates` Bot API to find `message_thread_id`
4. Run `nightcrawler init` or manually add `TELEGRAM_THREAD_ID=<id>` to config.sh

**Backward compatibility:** If `TELEGRAM_THREAD_ID` is empty, behavior is identical to today. No breaking change.

### Risk: Low
- `message_thread_id` is an optional parameter — Telegram ignores it if the group doesn't have Topics enabled
- `_tg_send` validates `ok: true` from Telegram API response. If a thread send fails (invalid ID, topic deleted), it retries once without `message_thread_id` so the message lands in General instead of being silently lost
- `escalate_urgent` retries 3 times as before — each attempt gets the thread→General fallback

---

## Phase 2: Multi-Stack Detection

### Problem
Clout is both Turborepo AND Foundry. Current `nightcrawler-init.sh` picks the first match and stops. Real projects are often multi-stack.

### Design

Replace single-match detection with accumulative detection:

```bash
DETECTED_STACKS=()
DETECTED_TOOLS=""
DETECTED_BUILD_PARTS=()
DETECTED_TEST_PARTS=()

# Each detector APPENDS instead of overwriting
if [[ -f "$dir/turbo.json" ]]; then
    DETECTED_STACKS+=("Turborepo")
    DETECTED_TOOLS="$DETECTED_TOOLS node pnpm turbo"
    DETECTED_BUILD_PARTS+=("pnpm turbo build")
    DETECTED_TEST_PARTS+=("pnpm turbo test")
    DEFAULT_INSTALL="pnpm install"
    DEFAULT_DEPS="test -d node_modules"
fi
if [[ -f "$dir/foundry.toml" ]]; then
    DETECTED_STACKS+=("Solidity/Foundry")
    DETECTED_TOOLS="$DETECTED_TOOLS forge"
    DETECTED_BUILD_PARTS+=("forge build")
    DETECTED_TEST_PARTS+=("forge test -v")
    # Don't override INSTALL/DEPS if already set by earlier detector (e.g. Node)
    DEFAULT_INSTALL="${DEFAULT_INSTALL:-}"
    DEFAULT_DEPS="${DEFAULT_DEPS:-test -d lib}"
fi
# NOTE: All detectors must use ${DEFAULT_INSTALL:-} and ${DEFAULT_DEPS:-} guards
# to avoid overwriting values set by earlier detectors. Only the first match sets them.
# ... same for Cargo.toml, go.mod, etc.

# Join helper — Bash IFS only uses first char, so " && " won't work with array join
_join_and() {
    local result=""
    for part in "$@"; do
        [[ -n "$result" ]] && result="$result && $part" || result="$part"
    done
    echo "$result"
}

# Combine
DEFAULT_BUILD=$(_join_and "${DETECTED_BUILD_PARTS[@]}")
DEFAULT_TEST=$(_join_and "${DETECTED_TEST_PARTS[@]}")
DETECTED_TOOLS=$(echo "$DETECTED_TOOLS" | tr ' ' '\n' | sort -u | tr '\n' ' ')
DETECTED_STACK=$(IFS=", "; echo "${DETECTED_STACKS[*]}")
```

**For Clout, this would produce:**
- Stack: `Turborepo, Solidity/Foundry`
- Build: `pnpm turbo build && forge build`
- Test: `pnpm turbo test && forge test -v`
- Tools: `forge node pnpm turbo`
- Deps: `test -d node_modules`
- Install: `pnpm install`

User can still override any of these at the prompt.

### Risk: Low
- Only changes the init CLI's suggestion logic, not runtime behavior
- User confirms everything before writing

---

## Phase 3: Config Validation on start.sh

### Problem
If config.sh is missing `BUILD_CMD` or `TEST_CMD`, the session burns Claude time before failing.

### Design

Add a validation step after sourcing config in `start.sh` (between current steps 4 and 5):

```bash
# 4b. Validate critical config
if [[ -f "$PROJECT_PATH/.nightcrawler/config.sh" ]]; then
    MISSING=""
    [[ -z "${BUILD_CMD:-}" ]] && MISSING="$MISSING BUILD_CMD"
    [[ -z "${TEST_CMD:-}" ]] && MISSING="$MISSING TEST_CMD"
    if [[ -n "$MISSING" ]]; then
        echo "WARNING: Missing in .nightcrawler/config.sh:$MISSING"
        echo "Session may fail. Run 'nightcrawler init' to fix."
    fi
else
    echo "WARNING: No .nightcrawler/config.sh found — using defaults"
fi
```

This warns but doesn't block — some projects legitimately have no build step (Python scripts).

### Risk: Zero
- Warning only, no behavior change

---

## Phase 4: `nightcrawler list`

### Problem
No way to see all registered projects and their health at a glance.

### Design

New script: `scripts/nightcrawler-list.sh` (~40 lines)

```
$ nightcrawler list
PROJECT     PATH                                STATUS    LAST SESSION
clout       /home/nightcrawler/projects/clout   OK        2026-03-04
my-api      /home/nightcrawler/projects/my-api  NO CONFIG never
```

Checks per project:
- Path exists?
- `.nightcrawler/config.sh` exists?
- Last session date (from `sessions/` directory)
- Active session? (lock held?)

Also add to NIGHTCRAWLER.md as a workspace command:
```
- `list` → exec: `bash /root/nightcrawler/scripts/nightcrawler-list.sh`
```

This goes in the STATIC_FOOTER of `generate-workspace.sh` since it's project-agnostic.

### Risk: Zero
- New file, read-only, no side effects

---

## Phase 5: `nightcrawler remove <project>`

### Problem
No clean way to deregister a project. Currently requires manually editing openclaw.yaml.

### Design

New script: `scripts/nightcrawler-remove.sh` (~60 lines)

**Lock guard (addresses active session desync):**
```bash
# Check if lock is ACTUALLY held by a live process (not just a stale file)
# Same flock -n pattern used by start.sh and generate-workspace.sh
LOCK_FILE="/tmp/nightcrawler-${PROJECT_NAME}.lock"
if [[ -f "$LOCK_FILE" ]] && ! flock -n "$LOCK_FILE" true 2>/dev/null; then
    echo "ERROR: Cannot remove '$PROJECT_NAME' — session is active (lock held at $LOCK_FILE)"
    echo "Run 'stop' first, then retry."
    exit 1
fi
```

```
$ nightcrawler remove my-api
Remove project 'my-api'?
  - Delete from openclaw.yaml
  - Regenerate workspace/NIGHTCRAWLER.md
  - .nightcrawler/ in project dir will NOT be deleted
Confirm (y/n): y
Removed.
```

```
$ nightcrawler remove clout
ERROR: Cannot remove 'clout' — session is active (lock held at /tmp/nightcrawler-clout.lock)
Run 'stop' first, then retry.
```

Uses `python3 + yaml.safe_load/dump` to remove the entry (same pattern as upsert). Does NOT delete the project directory or its `.nightcrawler/` folder — just deregisters it. **Refuses removal if a session lock is held** — prevents dispatcher/config desync while a session is running.

### Risk: Low
- Only modifies openclaw.yaml and regenerates workspace
- Lock guard prevents removal during active sessions

---

## Phase 6: `--non-interactive` Mode for Init

### Problem
Can't script project setup — init requires interactive prompts.

### Design

Add flag parsing to `nightcrawler-init.sh`:

```bash
nightcrawler init --non-interactive \
    --name my-api \
    --path /home/nightcrawler/projects/my-api \
    --branch main \
    --telegram-thread 12345
```

When `--non-interactive` is set:
- Auto-detect stack (no confirmation)
- Use detected defaults for all commands (no prompts)
- Skip preview/confirmation
- Write config and exit

Flags override detected defaults:
- `--build "custom build cmd"` — override build command
- `--test "custom test cmd"` — override test command
- `--install "custom install cmd"` — override install command

Only `--name` and `--path` are required in non-interactive mode.

### Risk: Zero
- New code path, existing interactive flow unchanged

---

## Phase 7: `--diff` Mode for generate-workspace.sh

### Problem
Regenerating workspace/NIGHTCRAWLER.md is the highest-risk operation (Haiku-facing). No way to preview changes.

### Design

Add `--diff` flag:

```bash
if [[ "${1:-}" == "--diff" ]]; then
    TEMP=$(mktemp)
    WORKSPACE="$TEMP"
    # ... generate to temp ...
    diff "$NC_ROOT/workspace/NIGHTCRAWLER.md" "$TEMP" || true
    rm "$TEMP"
    exit 0
fi
```

### Risk: Zero
- Read-only operation

---

## Phase 8: `--update` Mode for Init

### Problem
Re-running `nightcrawler init` on an existing project overwrites config.sh, losing manual edits.

### Design

If `.nightcrawler/config.sh` already exists, init enters update mode:
- Re-runs stack detection
- Shows current vs detected values side-by-side
- User picks per-field: keep current or use detected
- Only writes fields that changed

```
$ nightcrawler init --update
Existing config found for 'clout'

BUILD_CMD:
  current: pnpm turbo build && forge build
  detected: pnpm turbo build
  Keep current? [Y/n]:

TOOLS:
  current: pnpm turbo forge node
  detected: forge node pnpm turbo
  Keep current? [Y/n]:
```

### Risk: Low
- Only modifies config.sh with explicit user approval per field

---

## Phase 9: Simplified Init Flow (auto-detect + confirm)

### Problem
Current `nightcrawler-init.sh` asks 9 questions even when auto-detection gets everything right. Most users just want to name the project and go.

### Design

Reduce the happy path to **1 typed answer + 2 enters**:

```
$ nightcrawler init
🕷️ Nightcrawler — Project Setup

Project name: receipt-scanner
Project path [/home/user/receipt-scanner]:

Detected: package.json, tsconfig.json, turbo.json
Stack: Node.js/TypeScript, Turborepo

  BUILD_CMD="pnpm turbo build"
  TEST_CMD="pnpm turbo test"
  INSTALL_CMD="pnpm install"
  DEPS_CHECK="test -d node_modules"
  TOOLS="node pnpm turbo"
  BASE_BRANCH="main"
  TELEGRAM_THREAD_ID=""

Look good? [Y/n]: y

Creating .nightcrawler/config.sh ✓
Verifying tools... node ✓ pnpm ✓ turbo ✓
Creating .nightcrawler/CLAUDE.md ✓
Adding to openclaw.yaml ✓
Updating workspace commands ✓

Done. Run 'start receipt-scanner --budget 5' from Telegram.
```

If `n`, drops into per-field edit mode:

```
Look good? [Y/n]: n

Build command [pnpm turbo build]: pnpm turbo build && forge build
Test command [pnpm turbo test]: pnpm turbo test && forge test -v
Install command [pnpm install]:
Dependency check [test -d node_modules]:
Required tools [node pnpm turbo]: node pnpm turbo forge
Base branch [main]:
Telegram thread ID []: 48291

  BUILD_CMD="pnpm turbo build && forge build"
  ...

Look good? [Y/n]: y
Done.
```

**Tool verification after config write:**
```bash
_verify_tools() {
    local missing=()
    for tool in $TOOLS; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo "  $tool ✓"
        else
            echo "  $tool ✗"
            missing+=("$tool")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "WARNING: ${missing[*]} not found in PATH. Install before running sessions."
    fi
}
```

Same `command -v` check `diagnose.sh` uses. Warns but doesn't block — user may install tools later before first session.

**Code change:** Wrap per-field prompts in `if [[ "$confirm" != "y" ]]`. Detection runs unconditionally, prompts only appear on rejection.

### Risk: Zero
- Same init logic, just reordered. Detection unchanged, validation unchanged.

---

## Phase 10: VPS Bootstrap (`nightcrawler setup`)

### Problem
First-time VPS setup requires ~30 minutes of manual work: installing deps, configuring API keys, setting up OpenClaw, creating systemd service, deploying workspace. No documentation or automation exists.

### Design

New script: `scripts/nightcrawler-setup.sh` (~200 lines)

```
$ curl -s https://raw.githubusercontent.com/mateodaza/nightcrawler/main/scripts/nightcrawler-setup.sh | bash
```

Or after cloning:
```
$ ./scripts/nightcrawler-setup.sh
```

**Interactive flow:**

```
🕷️ Nightcrawler — VPS Setup

Checking prerequisites...
  git ✓
  python3 ✓
  node ✓ (v24.14.0)
  npm ✓
  PyYAML ✓

Step 1/5: API Keys
  ANTHROPIC_API_KEY: sk-ant-... ✓ (already in ~/.env)
  OPENAI_API_KEY: sk-... ✓ (already in ~/.env)
  Missing keys? Enter them now (or skip to add later):
  ANTHROPIC_API_KEY [skip]:
  OPENAI_API_KEY [skip]:

Step 2/5: Claude Code CLI
  claude --version: 2.1.63 ✓
  Auth: Max subscription ✓
  (If missing: prompts 'npm install -g @anthropic-ai/claude-code && claude login')

Step 3/5: Codex CLI
  codex --version: 1.2.0 ✓
  (If missing: prompts 'npm install -g @openai/codex')

Step 4/5: Telegram Bot
  TELEGRAM_BOT_TOKEN [skip]:
  TELEGRAM_CHAT_ID [skip]:
  (If provided: sends test message "🕷️ Nightcrawler connected" to verify)

Step 5/5: OpenClaw (optional — needed for Telegram dispatch)
  openclaw --version: 2026.2.26 ✓
  Configure workspace? [Y/n]: y
  Deploying workspace files... ✓
  Creating systemd service... ✓
  Starting openclaw-gateway... ✓

Setup complete.
Run 'nightcrawler init' in your project directory to get started.
```

**What it does:**

| Step | Action | If missing |
|------|--------|------------|
| Prerequisites | Check git, python3, node, npm, PyYAML | Print install commands, don't auto-install |
| API Keys | Check `~/.env` for ANTHROPIC_API_KEY, OPENAI_API_KEY | Prompt to enter, append to `~/.env` |
| Claude CLI | Check `claude --version` | Print `npm install -g @anthropic-ai/claude-code && claude login` |
| Codex CLI | Check `codex --version` | Print `npm install -g @openai/codex` |
| Telegram | Check `~/.env` for bot token + chat ID | Prompt to enter, send test message to verify |
| OpenClaw | Check `openclaw --version` | Print install command. If present: deploy workspace, create systemd unit, start service |

**Key principles:**
- **Never auto-install** system packages — print what's needed, let the user decide. Different distros have different package managers.
- **Idempotent** — safe to run multiple times. Skips what's already configured.
- **API keys stay in `~/.env`** — single source of truth, same as today.
- **OpenClaw is optional** — Nightcrawler works without it (just no Telegram dispatch). Setup asks, doesn't force.
- **Telegram test message** — if bot token + chat ID are provided, sends a test to verify before proceeding.

**Privilege handling for systemd operations:**

The bootstrap script needs to write to `/etc/systemd/system/` and run `systemctl` — both require root or sudo. Rather than assuming root, the script detects the current privilege level and adapts:

```bash
_needs_sudo() {
    [[ $(id -u) -ne 0 ]]
}

_run_privileged() {
    if _needs_sudo; then
        sudo "$@"
    else
        "$@"
    fi
}
```

If not root, the script checks for `sudo` availability upfront:
```bash
if _needs_sudo; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "WARNING: Not running as root and 'sudo' not found."
        echo "Systemd service setup requires root privileges."
        echo "Either re-run as root or install sudo."
        echo ""
        echo "To set up the service manually, run as root:"
        _generate_systemd_unit
        echo ""
        echo "Save the above to /etc/systemd/system/openclaw-gateway.service"
        echo "Then: systemctl daemon-reload && systemctl enable --now openclaw-gateway"
        return 1
    fi
    echo "Systemd setup requires root. You may be prompted for your password."
fi
```

The systemd install step then uses `_run_privileged`:
```bash
_install_systemd_service() {
    local unit_file="/etc/systemd/system/openclaw-gateway.service"

    _generate_systemd_unit | _run_privileged tee "$unit_file" > /dev/null
    _run_privileged systemctl daemon-reload
    _run_privileged systemctl enable --now openclaw-gateway
    echo "OpenClaw gateway service installed and started ✓"
}
```

**Graceful degradation:** If not root AND no sudo, the script doesn't fail — it prints the unit file content and manual instructions. The user can copy-paste and run as root later. This keeps the rest of the setup (API keys, CLI checks, workspace deploy) working regardless of privilege level.

**`set -e` safety:** The systemd step must be called as a non-fatal operation so `return 1` from the no-sudo path doesn't exit the whole script:
```bash
# In the main setup flow (Step 5):
_install_systemd_service || echo "Skipping service install (manual step required)"
```
This ensures the "no sudo" graceful-degrade path logs a warning and continues instead of tripping `set -e`.

**systemd unit generation (resolved at runtime, never hardcoded):**
```bash
_generate_systemd_unit() {
    local node_bin openclaw_bin
    node_bin=$(command -v node) || { echo "ERROR: node not found in PATH"; return 1; }
    openclaw_bin=$(command -v openclaw) || { echo "ERROR: openclaw not found in PATH"; return 1; }

    cat << EOF
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=$HOME
ExecStart=$node_bin $openclaw_bin gateway
Restart=always
RestartSec=10
Environment=HOME=$HOME

[Install]
WantedBy=multi-user.target
EOF
}
```

Paths are resolved from `command -v` at generation time — works regardless of nvm version, install method, or user.

**Workspace deployment:**
```bash
# Copy workspace files from nightcrawler repo to OpenClaw workspace
cp "$NC_ROOT/workspace/"*.md ~/.openclaw/workspace/
echo "Deployed $(ls "$NC_ROOT/workspace/"*.md | wc -l) workspace files"
```

Same as `scripts/deploy-workspace.sh` but integrated into the setup flow.

### Risk: Low
- New script, no existing changes
- Never modifies system packages
- Idempotent — safe to re-run
- OpenClaw step is optional

---

## Implementation Order

| Phase | Description | Risk | Depends on |
|-------|-------------|------|------------|
| 1 | Telegram threads per project | Low | v1 done |
| 2 | Multi-stack detection | Low | v1 done |
| 3 | Config validation | Zero | v1 done |
| 4 | `nightcrawler list` | Zero | v1 done |
| 5 | `nightcrawler remove` | Low | v1 done |
| 6 | `--non-interactive` init | Zero | Phase 2 (multi-stack) |
| 7 | `--diff` for workspace gen | Zero | v1 done |
| 8 | `--update` init mode | Low | Phase 2 (multi-stack) |
| 9 | Simplified init flow | Zero | Phase 2 (multi-stack) |
| 10 | VPS bootstrap (`nightcrawler setup`) | Low | v1 done |

Phases 1-5, 7, 10 are independent. Phase 6, 8, 9 depend on Phase 2 (multi-stack detection).

**Recommended first batch:** Phases 1 + 2 + 3 (highest impact, low risk, independent)
**Second batch:** Phases 4 + 5 + 7 + 9 (quality of life, zero risk)
**Third batch:** Phases 6 + 8 (scripting and updates, depend on earlier phases)
**Fourth batch:** Phase 10 (VPS bootstrap — standalone, do when ready to share with others)

---

## What Does NOT Change
- `nightcrawler.sh` core loop (except `notify_normal`/`escalate_urgent` refactor in Phase 1)
- `diagnose.sh` — no modifications
- Budget system, task queue, journal, crash recovery — all untouched
- SOUL.md, IDENTITY.md — personality is project-agnostic
- `nightcrawler-init.sh` core logic (Phase 9 just reorders prompts, doesn't change detection/validation)
- `~/.env` as single source of truth for API keys (Phase 10 reads/appends, never replaces)
