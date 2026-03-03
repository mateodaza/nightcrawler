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

# 4. Source project config (needed before dependency install)
INSTALL_CMD=""
WORKDIR=""
if [[ -f "$PROJECT_PATH/.nightcrawler/config.sh" ]]; then
    # shellcheck source=/dev/null
    source "$PROJECT_PATH/.nightcrawler/config.sh"
fi

# 5. Install dependencies if node_modules is missing
INSTALL_DIR="$PROJECT_PATH"
[[ -n "$WORKDIR" ]] && INSTALL_DIR="$PROJECT_PATH/$WORKDIR"

if [[ -n "$INSTALL_CMD" ]]; then
    if [[ ! -d "$INSTALL_DIR/node_modules" ]]; then
        echo "Installing dependencies (node_modules missing, using INSTALL_CMD)..."
        (cd "$INSTALL_DIR" && eval "$INSTALL_CMD" 2>&1 | tail -5)
    fi
elif [[ -f "$INSTALL_DIR/pnpm-lock.yaml" ]] && [[ ! -d "$INSTALL_DIR/node_modules" ]]; then
    echo "Installing dependencies (node_modules missing)..."
    (cd "$INSTALL_DIR" && pnpm install 2>&1 | tail -5)
elif [[ -f "$INSTALL_DIR/package-lock.json" ]] && [[ ! -d "$INSTALL_DIR/node_modules" ]]; then
    echo "Installing dependencies (node_modules missing)..."
    (cd "$INSTALL_DIR" && npm install 2>&1 | tail -5)
fi

# 6. Refresh .claude/CLAUDE.md from repo-owned .nightcrawler/CLAUDE.md
mkdir -p "$PROJECT_PATH/.claude"
if [[ -f "$PROJECT_PATH/.nightcrawler/CLAUDE.md" ]]; then
    cp "$PROJECT_PATH/.nightcrawler/CLAUDE.md" "$PROJECT_PATH/.claude/CLAUDE.md"
    echo "Refreshed .claude/CLAUDE.md from .nightcrawler/CLAUDE.md"
elif [[ ! -f "$PROJECT_PATH/.claude/CLAUDE.md" ]]; then
    # Generic fallback — only if nothing exists at all
    cat > "$PROJECT_PATH/.claude/CLAUDE.md" << 'CLAUDEEOF'
# Project Context

## Build & Test
Check `.nightcrawler/config.sh` for BUILD_CMD and TEST_CMD.

## Rules
- Read existing source before modifying anything
- Keep changes minimal and focused
- Run build and test commands to verify before finishing
CLAUDEEOF
    echo "Created generic .claude/CLAUDE.md (no .nightcrawler/CLAUDE.md found)"
fi

# 7. Refresh .claude/skills/ from repo-owned .nightcrawler/skills/ (atomic replace)
if [[ -d "$PROJECT_PATH/.nightcrawler/skills" ]]; then
    # Atomic replace: copy to temp, swap in
    SKILLS_TMP="$PROJECT_PATH/.claude/skills.tmp.$$"
    rm -rf "$SKILLS_TMP"
    cp -r "$PROJECT_PATH/.nightcrawler/skills" "$SKILLS_TMP"
    rm -rf "$PROJECT_PATH/.claude/skills"
    mv "$SKILLS_TMP" "$PROJECT_PATH/.claude/skills"
    echo "Refreshed .claude/skills/ from .nightcrawler/skills/"
else
    # No project skills — clean up any stale ones
    rm -rf "$PROJECT_PATH/.claude/skills"
fi

# 8. Ensure .claude/settings.json exists for Claude Code CLI permissions
if [[ ! -f "$PROJECT_PATH/.claude/settings.json" ]]; then
    echo "Creating .claude/settings.json for tool permissions"
    cat > "$PROJECT_PATH/.claude/settings.json" << 'SETTINGSEOF'
{
  "permissions": {
    "allow": [
      "Bash(forge *)",
      "Bash(cast *)",
      "Bash(pnpm *)",
      "Bash(npm *)",
      "Bash(npx *)",
      "Bash(turbo *)",
      "Bash(node *)",
      "Bash(cat *)",
      "Bash(ls *)",
      "Bash(find *)",
      "Bash(mkdir *)",
      "Bash(cp *)",
      "Bash(mv *)",
      "Bash(head *)",
      "Bash(tail *)",
      "Bash(wc *)",
      "Bash(diff *)",
      "Bash(git status*)",
      "Bash(git diff*)",
      "Bash(git log*)",
      "Read",
      "Write",
      "Edit",
      "Glob",
      "Grep"
    ],
    "deny": [
      "Bash(curl*)",
      "Bash(wget*)",
      "Bash(ssh*)",
      "Bash(scp*)",
      "Bash(git push*)",
      "Bash(git reset*)",
      "Bash(sudo*)",
      "Bash(rm -rf /*)",
      "Bash(rm -rf ~*)",
      "Bash(chmod 777*)",
      "Bash(pkill*)",
      "Bash(kill*)"
    ]
  }
}
SETTINGSEOF
fi

# 9. Kill budget-kill flag from previous stop command
rm -f /tmp/nightcrawler-budget-kill

# --- Launch ---
echo "Pre-flight complete. Launching nightcrawler.sh $*"
nohup bash "$SCRIPTS/nightcrawler.sh" "$@" > /tmp/nightcrawler-${PROJECT}-stdout.log 2>&1 &
disown

echo "Session started (PID $!). Use 'status' to monitor."
