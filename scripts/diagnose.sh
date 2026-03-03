#!/usr/bin/env bash
# diagnose.sh [project] [--install]
# Generic project diagnostics. Sources .nightcrawler/config.sh for project-specific commands.
# With --install: runs INSTALL_CMD (or auto-detects pnpm/npm).

set -euo pipefail

# Ensure tool paths are available
for p in "$HOME/.foundry/bin" "$HOME/.cargo/bin" "/usr/local/bin" "$HOME/.local/bin"; do
    [[ -d "$p" ]] && PATH="$p:$PATH"
done
export PATH

# --- Resolve project ---
INSTALL_MODE=false
PROJECT=""

for arg in "$@"; do
    case "$arg" in
        --install) INSTALL_MODE=true ;;
        *) PROJECT="$arg" ;;
    esac
done

# Auto-detect from active marker, then last session
if [[ -z "$PROJECT" ]]; then
    PROJECT=$(cat /tmp/nightcrawler-active-project 2>/dev/null | head -1)
fi
if [[ -z "$PROJECT" ]]; then
    SESSION=$(ls -t /home/nightcrawler/nightcrawler/sessions/ 2>/dev/null | head -1)
    if [[ -n "$SESSION" ]]; then
        PROJECT=$(echo "$SESSION" | sed 's/^[0-9]*-[0-9]*-//')
    fi
fi
if [[ -z "$PROJECT" ]]; then
    echo "No project specified and no active/recent session found."
    exit 1
fi

PROJECT_PATH="${NIGHTCRAWLER_PROJECT_PATH:-/home/nightcrawler/projects/$PROJECT}"

if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "FATAL: Project directory not found: $PROJECT_PATH"
    exit 1
fi

# --- Load project config ---
BUILD_CMD="make build"
TEST_CMD="make test"
INSTALL_CMD=""
WORKDIR=""

if [[ -f "$PROJECT_PATH/.nightcrawler/config.sh" ]]; then
    # shellcheck source=/dev/null
    source "$PROJECT_PATH/.nightcrawler/config.sh"
fi

# Resolve working directory
if [[ -n "$WORKDIR" ]]; then
    cd "$PROJECT_PATH/$WORKDIR"
else
    cd "$PROJECT_PATH"
fi

# --- Install mode ---
if [[ "$INSTALL_MODE" == true ]]; then
    echo "=== INSTALLING: $PROJECT ==="
    if [[ -n "$INSTALL_CMD" ]]; then
        eval "$INSTALL_CMD" 2>&1 | tail -30
    elif [[ -f pnpm-lock.yaml ]]; then
        pnpm install 2>&1 | tail -30
    elif [[ -f package-lock.json ]]; then
        npm install 2>&1 | tail -30
    elif [[ -f yarn.lock ]]; then
        yarn install 2>&1 | tail -30
    else
        echo "No lock file found and no INSTALL_CMD in config. Nothing to install."
    fi
    exit 0
fi

# --- Diagnose mode ---
echo "=== PROJECT: $PROJECT ==="
echo "Path: $PROJECT_PATH"

echo ""
echo "=== BRANCH ==="
git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "Not a git repo"
git log --oneline -3 2>/dev/null || true

echo ""
echo "=== DEPS ==="
if [[ -f pnpm-lock.yaml ]]; then
    test -d node_modules && echo "pnpm: node_modules OK" || echo "pnpm: node_modules MISSING — run: install $PROJECT"
elif [[ -f package-lock.json ]]; then
    test -d node_modules && echo "npm: node_modules OK" || echo "npm: node_modules MISSING — run: install $PROJECT"
else
    echo "No JS package manager detected"
fi
command -v forge >/dev/null 2>&1 && echo "forge: $(forge --version 2>&1 | head -1)" || echo "forge: NOT INSTALLED"

echo ""
echo "=== BUILD ==="
set +e
eval "$BUILD_CMD" 2>&1 | tail -20
BUILD_EXIT=$?
set -e
[[ $BUILD_EXIT -eq 0 ]] && echo "Build: OK" || echo "Build: FAILED (exit $BUILD_EXIT)"

echo ""
echo "=== TEST ==="
set +e
eval "$TEST_CMD" 2>&1 | tail -30
TEST_EXIT=$?
set -e
[[ $TEST_EXIT -eq 0 ]] && echo "Test: OK" || echo "Test: FAILED (exit $TEST_EXIT)"
