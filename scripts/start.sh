#!/usr/bin/env bash
# start.sh — Pre-flight + launch wrapper for nightcrawler.sh
# Handles all cleanup so "start clout --budget 15" works from phone via OpenClaw.
#
# Usage: start.sh <project> [--budget N] [--dry-run]

set -euo pipefail

PROJECT="${1:?Usage: start.sh <project> [--budget N] [--dry-run]}"
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
PROJECT_PATH="${NIGHTCRAWLER_PROJECT_PATH:-/home/nightcrawler/projects/$PROJECT}"
LOCKFILE="/tmp/nightcrawler-${PROJECT}.lock"
CONTROL_DIR="/tmp/nightcrawler/${PROJECT}"

# --- Pre-flight checks ---

# 1. Project exists
if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "FATAL: Project directory not found: $PROJECT_PATH"
    exit 1
fi

# 2. Clear stale lock — only if no live process holds it
if [[ -f "$LOCKFILE" ]]; then
    if flock -n "$LOCKFILE" true 2>/dev/null; then
        echo "Cleared stale lock file"
        rm -f "$LOCKFILE"
    else
        echo "FATAL: Another session is actively running (lock held by live process)"
        exit 1
    fi
fi

# 3. Clear skip file from previous sessions
if [[ -f "$CONTROL_DIR/skip" ]]; then
    echo "Cleared skip file ($(wc -l < "$CONTROL_DIR/skip") entries)"
    rm -f "$CONTROL_DIR/skip"
fi

# 4. Ensure .claude/CLAUDE.md exists for Claude Code CLI context
if [[ ! -f "$PROJECT_PATH/.claude/CLAUDE.md" ]]; then
    echo "Creating .claude/CLAUDE.md for project context"
    mkdir -p "$PROJECT_PATH/.claude"
    cat > "$PROJECT_PATH/.claude/CLAUDE.md" << 'CLAUDEEOF'
# Clout — Solidity/Foundry Project

## Key Files
- RESEARCH.md — canonical struct definitions, state machine, and protocol spec
- GLOBAL_PLAN.md — overall architecture and task sequencing
- foundry.toml — Solidity config (check version here)
- src/ — production contracts
- test/ — Foundry tests

## Rules
- Match the pragma version in foundry.toml
- Follow OpenZeppelin patterns (ReentrancyGuard, Ownable, IERC20)
- All amounts use 6 decimals (stablecoin native)
- Read RESEARCH.md before planning any contract — it's the source of truth for structs and state machines
- Named imports only (`import {X} from "..."`)
- Read memory.md if it exists for project patterns
CLAUDEEOF
fi

# 5. Kill budget-kill flag from previous stop command
rm -f /tmp/nightcrawler-budget-kill

# --- Launch ---
echo "Pre-flight complete. Launching nightcrawler.sh $*"
nohup bash "$SCRIPTS/nightcrawler.sh" "$@" > /tmp/nightcrawler-${PROJECT}-stdout.log 2>&1 &
disown

echo "Session started (PID $!). Use 'status' to monitor."
