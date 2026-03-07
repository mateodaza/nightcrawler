#!/usr/bin/env bash
# start.sh — Pre-flight + launch wrapper for nightcrawler.sh
# Handles all cleanup so "start clout --budget 15" works from phone via OpenClaw.
#
# Usage: start.sh <project> [--budget N] [--dry-run]

set -euo pipefail

# Ensure tool paths are available (nohup/systemd don't source shell profiles)
NVM_BIN=$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1)
for p in "$HOME/.foundry/bin" "$HOME/.cargo/bin" "/usr/local/bin" "$HOME/.local/bin" "$NVM_BIN"; do
    [[ -d "$p" ]] && PATH="$p:$PATH"
done
export PATH

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

# 4. Source project config (needed before dependency install + permissions)
INSTALL_CMD=""
WORKDIR=""
DEPS_CHECK=""
TOOLS=""
TOOLS_ALLOW=""
TELEGRAM_THREAD_ID=""
if [[ -f "$PROJECT_PATH/.nightcrawler/config.sh" ]]; then
    # shellcheck source=/dev/null
    source "$PROJECT_PATH/.nightcrawler/config.sh"
fi

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

# 5. Initialize git submodules if any are missing
if [[ -f "$PROJECT_PATH/.gitmodules" ]]; then
    NEED_SM=false
    while IFS= read -r sm_path; do
        if [[ ! -f "$PROJECT_PATH/$sm_path/.git" && ! -d "$PROJECT_PATH/$sm_path/.git" ]]; then
            NEED_SM=true; break
        fi
    done < <(git -C "$PROJECT_PATH" config --file .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}')
    if [[ "$NEED_SM" == true ]]; then
        echo "Initializing git submodules..."
        git -C "$PROJECT_PATH" submodule update --init --recursive 2>&1 | tail -5
    fi
fi

# 6. Install dependencies if needed
INSTALL_DIR="$PROJECT_PATH"
[[ -n "$WORKDIR" ]] && INSTALL_DIR="$PROJECT_PATH/$WORKDIR"

NEED_INSTALL=false
if [[ -n "$DEPS_CHECK" ]]; then
    # Config-driven check (generic)
    if ! (cd "$INSTALL_DIR" && eval "$DEPS_CHECK") >/dev/null 2>&1; then
        NEED_INSTALL=true
    fi
elif [[ -d "$INSTALL_DIR" ]] && [[ ! -d "$INSTALL_DIR/node_modules" ]]; then
    # Legacy fallback: check node_modules
    if [[ -f "$INSTALL_DIR/pnpm-lock.yaml" ]] || [[ -f "$INSTALL_DIR/package-lock.json" ]]; then
        NEED_INSTALL=true
    fi
fi

if [[ "$NEED_INSTALL" == true ]] && [[ -n "$INSTALL_CMD" ]]; then
    echo "Installing dependencies..."
    (cd "$INSTALL_DIR" && eval "$INSTALL_CMD" 2>&1 | tail -5)
elif [[ "$NEED_INSTALL" == true ]]; then
    # Auto-detect (legacy fallback)
    if [[ -f "$INSTALL_DIR/pnpm-lock.yaml" ]]; then
        (cd "$INSTALL_DIR" && pnpm install 2>&1 | tail -5)
    elif [[ -f "$INSTALL_DIR/package-lock.json" ]]; then
        (cd "$INSTALL_DIR" && npm install 2>&1 | tail -5)
    fi
fi

# 7. Refresh .claude/CLAUDE.md from repo-owned .nightcrawler/CLAUDE.md
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

# 8. Refresh .claude/skills/ from repo-owned .nightcrawler/skills/ (atomic replace)
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

# 9. Generate .claude/settings.json from config (always refresh)
_generate_settings() {
    local allow_tools="${TOOLS_ALLOW:-}"
    if [[ -z "$allow_tools" ]]; then
        # Default: safe utils + TOOLS from config
        allow_tools="cat ls find mkdir cp mv head tail wc diff"
        for t in $TOOLS; do
            allow_tools="$allow_tools $t"
        done
    fi

    python3 -c "
import json, sys
tools = '${allow_tools}'.split()
allow = [f'Bash({t} *)' for t in tools]
# Safe defaults always included
allow += [
    'Bash(cat *)', 'Bash(ls *)', 'Bash(find *)', 'Bash(mkdir *)',
    'Bash(cp *)', 'Bash(mv *)', 'Bash(head *)', 'Bash(tail *)',
    'Bash(wc *)', 'Bash(diff *)',
    'Bash(git status*)', 'Bash(git diff*)', 'Bash(git log*)',
    'Read', 'Write', 'Edit', 'Glob', 'Grep'
]
# Deduplicate while preserving order
seen = set()
unique = []
for item in allow:
    if item not in seen:
        seen.add(item)
        unique.append(item)
deny = [
    'Bash(curl*)', 'Bash(wget*)', 'Bash(ssh*)', 'Bash(scp*)',
    'Bash(git push*)', 'Bash(git reset*)', 'Bash(sudo*)',
    'Bash(rm -rf /*)', 'Bash(rm -rf ~*)', 'Bash(chmod 777*)',
    'Bash(pkill*)', 'Bash(kill*)'
]
json.dump({'permissions': {'allow': unique, 'deny': deny}}, sys.stdout, indent=2)
" > "$PROJECT_PATH/.claude/settings.json"
}

_generate_settings
echo "Generated .claude/settings.json from config"

# Ensure auto-generated files are gitignored (settings.json is never hand-edited)
if [[ -f "$PROJECT_PATH/.gitignore" ]]; then
    grep -qF '.claude/settings.json' "$PROJECT_PATH/.gitignore" 2>/dev/null || \
        echo '.claude/settings.json' >> "$PROJECT_PATH/.gitignore"
else
    echo '.claude/settings.json' > "$PROJECT_PATH/.gitignore"
fi

# 10. Kill budget-kill flag from previous stop command
rm -f /tmp/nightcrawler-budget-kill

# --- Launch ---
echo "Pre-flight complete. Launching nightcrawler.sh $*"
nohup bash "$SCRIPTS/nightcrawler.sh" "$@" > /tmp/nightcrawler-${PROJECT}-stdout.log 2>&1 &
disown

echo "Session started (PID $!). Use 'status' to monitor."
