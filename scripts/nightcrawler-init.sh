#!/usr/bin/env bash
# nightcrawler-init.sh — Interactive CLI to onboard a project into Nightcrawler.
# Creates .nightcrawler/config.sh, .nightcrawler/CLAUDE.md, updates openclaw.yaml,
# and regenerates workspace/NIGHTCRAWLER.md.
#
# Usage: nightcrawler-init.sh [options] [project-path]
#   --non-interactive    Auto-detect and write config without prompts
#   --update             Re-detect stack, show current vs detected, per-field confirm
#   --name NAME          Project name (required for --non-interactive)
#   --path PATH          Project path
#   --branch BRANCH      Base branch (default: main)
#   --build CMD          Override build command
#   --test CMD           Override test command
#   --install CMD        Override install command
#   --telegram-thread ID Telegram thread ID

set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
NC_ROOT="$(dirname "$SCRIPTS")"
YAML="$NC_ROOT/config/openclaw.yaml"

# --- Flag parsing ---
NON_INTERACTIVE=false
UPDATE_MODE=false
OPT_NAME="" OPT_PATH="" OPT_BRANCH="" OPT_BUILD="" OPT_TEST="" OPT_INSTALL="" OPT_THREAD=""
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive) NON_INTERACTIVE=true; shift ;;
        --update) UPDATE_MODE=true; shift ;;
        --name) OPT_NAME="$2"; shift 2 ;;
        --path) OPT_PATH="$2"; shift 2 ;;
        --branch) OPT_BRANCH="$2"; shift 2 ;;
        --build) OPT_BUILD="$2"; shift 2 ;;
        --test) OPT_TEST="$2"; shift 2 ;;
        --install) OPT_INSTALL="$2"; shift 2 ;;
        --telegram-thread) OPT_THREAD="$2"; shift 2 ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

# --- Helpers ---

validate_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9_-]*[a-zA-Z0-9])?$ ]]; then
        echo "ERROR: Project name must be alphanumeric (hyphens/underscores allowed, no leading/trailing)" >&2
        return 1
    fi
    if [[ ${#name} -gt 50 ]]; then
        echo "ERROR: Project name too long (max 50 chars)" >&2
        return 1
    fi
    return 0
}

validate_cmd() {
    local cmd="$1" label="$2"
    if [[ -z "$cmd" ]]; then return 0; fi
    if [[ ${#cmd} -gt 200 ]]; then
        echo "ERROR: $label too long (max 200 chars)" >&2; return 1
    fi
    # Strip allowed '&&' sequences, then check for dangerous metacharacters
    local stripped="${cmd//&&/}"
    if [[ "$stripped" =~ [\;\|\&\$\`\(\)] ]]; then
        echo "ERROR: $label contains shell metacharacters (only && is allowed for chaining)" >&2; return 1
    fi
    return 0
}

prompt() {
    local varname="$1" label="$2" default="${3:-}"
    local input
    if [[ -n "$default" ]]; then
        printf "%s [%s]: " "$label" "$default" >&2
    else
        printf "%s: " "$label" >&2
    fi
    read -r input
    input="${input:-$default}"
    eval "$varname=\$input"
}

# --- Pre-flight ---

if ! python3 -c "import yaml" 2>/dev/null; then
    echo "ERROR: PyYAML is required. Install with: pip install pyyaml"
    exit 1
fi

echo "Nightcrawler — Project Setup"
echo ""

# --- 1. Project path ---
PROJECT_DIR="${OPT_PATH:-${POSITIONAL[0]:-}}"
if [[ -z "$PROJECT_DIR" ]]; then
    if [[ "$NON_INTERACTIVE" == true ]]; then
        echo "ERROR: --path is required in non-interactive mode" >&2
        exit 1
    fi
    prompt PROJECT_DIR "Project path" "$(pwd)"
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)" # resolve to absolute

if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "ERROR: Directory not found: $PROJECT_DIR"
    exit 1
fi

# --- 2. Project name ---
DEFAULT_NAME="$(basename "$PROJECT_DIR")"
if [[ -n "$OPT_NAME" ]]; then
    PROJECT_NAME="$OPT_NAME"
elif [[ "$NON_INTERACTIVE" == true ]]; then
    PROJECT_NAME="$DEFAULT_NAME"
else
    prompt PROJECT_NAME "Project name" "$DEFAULT_NAME"
fi

if ! validate_name "$PROJECT_NAME"; then
    exit 1
fi

# --- 3. Base branch ---
DEFAULT_BRANCH="main"
if [[ -d "$PROJECT_DIR/.git" ]]; then
    DEFAULT_BRANCH=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
fi
if [[ -n "$OPT_BRANCH" ]]; then
    BASE_BRANCH="$OPT_BRANCH"
elif [[ "$NON_INTERACTIVE" == true ]]; then
    BASE_BRANCH="$DEFAULT_BRANCH"
else
    prompt BASE_BRANCH "Base branch" "$DEFAULT_BRANCH"
fi

# --- 4. Auto-detect stack ---
echo ""
echo "Scanning $PROJECT_DIR..."

DETECTED_STACK=""
DEFAULT_BUILD=""
DEFAULT_TEST=""
DEFAULT_INSTALL=""
DEFAULT_DEPS=""
DEFAULT_TOOLS=""

_join_and() {
    local result=""
    for part in "$@"; do
        [[ -n "$result" ]] && result="$result && $part" || result="$part"
    done
    echo "$result"
}

detect_stack() {
    local dir="$1"
    local -a stacks=() build_parts=() test_parts=()
    local tools=""

    # Accumulative detection — multiple stacks can match
    if [[ -f "$dir/turbo.json" ]]; then
        stacks+=("Turborepo")
        tools="$tools node pnpm turbo"
        build_parts+=("pnpm turbo build")
        test_parts+=("pnpm turbo test")
        DEFAULT_INSTALL="${DEFAULT_INSTALL:-pnpm install}"
        DEFAULT_DEPS="${DEFAULT_DEPS:-test -d node_modules}"
    fi
    if [[ -f "$dir/foundry.toml" ]]; then
        stacks+=("Solidity/Foundry")
        tools="$tools forge"
        build_parts+=("forge build")
        test_parts+=("forge test -v")
        DEFAULT_DEPS="${DEFAULT_DEPS:-test -d lib}"
    fi
    if [[ -f "$dir/Cargo.toml" ]]; then
        stacks+=("Rust")
        tools="$tools cargo rustc"
        build_parts+=("cargo build")
        test_parts+=("cargo test")
        DEFAULT_DEPS="${DEFAULT_DEPS:-test -f Cargo.lock}"
    fi
    if [[ -f "$dir/go.mod" ]]; then
        stacks+=("Go")
        tools="$tools go"
        build_parts+=("go build ./...")
        test_parts+=("go test ./...")
        DEFAULT_DEPS="${DEFAULT_DEPS:-test -f go.sum}"
    fi
    if [[ -f "$dir/pyproject.toml" ]]; then
        stacks+=("Python")
        tools="$tools python3 pip"
        build_parts+=("python3 -m compileall src")
        test_parts+=("python -m pytest -v")
        DEFAULT_INSTALL="${DEFAULT_INSTALL:-pip install -e .}"
        DEFAULT_DEPS="${DEFAULT_DEPS:-test -d .venv}"
    elif [[ -f "$dir/requirements.txt" ]]; then
        stacks+=("Python")
        tools="$tools python3 pip pytest"
        build_parts+=("python3 -m compileall src")
        test_parts+=("python -m pytest -v")
        DEFAULT_INSTALL="${DEFAULT_INSTALL:-pip install -r requirements.txt}"
        DEFAULT_DEPS="${DEFAULT_DEPS:-test -d .venv}"
    fi
    # Node detection only if no turbo already matched (turbo implies Node)
    if [[ ${#stacks[@]} -eq 0 ]] || ! printf '%s\n' "${stacks[@]}" | grep -q "Turborepo"; then
        if [[ -f "$dir/pnpm-lock.yaml" ]]; then
            stacks+=("Node.js/pnpm")
            tools="$tools node pnpm"
            build_parts+=("pnpm build")
            test_parts+=("pnpm test")
            DEFAULT_INSTALL="${DEFAULT_INSTALL:-pnpm install}"
            DEFAULT_DEPS="${DEFAULT_DEPS:-test -d node_modules}"
        elif [[ -f "$dir/package-lock.json" ]]; then
            stacks+=("Node.js/npm")
            tools="$tools node npm"
            build_parts+=("npm run build")
            test_parts+=("npm test")
            DEFAULT_INSTALL="${DEFAULT_INSTALL:-npm install}"
            DEFAULT_DEPS="${DEFAULT_DEPS:-test -d node_modules}"
        elif [[ -f "$dir/package.json" ]]; then
            stacks+=("Node.js")
            tools="$tools node npm"
            build_parts+=("npm run build")
            test_parts+=("npm test")
            DEFAULT_INSTALL="${DEFAULT_INSTALL:-npm install}"
            DEFAULT_DEPS="${DEFAULT_DEPS:-test -d node_modules}"
        fi
    fi

    if [[ ${#stacks[@]} -gt 0 ]]; then
        DETECTED_STACK=$(IFS=", "; echo "${stacks[*]}")
        DEFAULT_BUILD=$(_join_and "${build_parts[@]}")
        DEFAULT_TEST=$(_join_and "${test_parts[@]}")
        DEFAULT_TOOLS=$(echo "$tools" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')
    fi
}

detect_stack "$PROJECT_DIR"

if [[ -n "$DETECTED_STACK" ]]; then
    echo "Detected: $DETECTED_STACK"
else
    echo "No known stack detected. You'll need to provide commands manually."
fi

# --- 5. Set defaults from detection (flags override) ---
BUILD_CMD="${OPT_BUILD:-$DEFAULT_BUILD}"
TEST_CMD="${OPT_TEST:-$DEFAULT_TEST}"
INSTALL_CMD="${OPT_INSTALL:-$DEFAULT_INSTALL}"
DEPS_CHECK="$DEFAULT_DEPS"
TOOLS="$DEFAULT_TOOLS"
TOOLS_ALLOW="$DEFAULT_TOOLS"
TELEGRAM_THREAD_ID="${OPT_THREAD:-}"

# --- 5b. Update mode: load existing config, show current vs detected ---
if [[ "$UPDATE_MODE" == true ]] && [[ -f "$PROJECT_DIR/.nightcrawler/config.sh" ]]; then
    echo "Existing config found for '$PROJECT_NAME'"
    # Load current values
    CUR_BUILD="" CUR_TEST="" CUR_INSTALL="" CUR_DEPS="" CUR_TOOLS="" CUR_THREAD=""
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/.nightcrawler/config.sh"
    CUR_BUILD="$BUILD_CMD" CUR_TEST="$TEST_CMD" CUR_INSTALL="$INSTALL_CMD"
    CUR_DEPS="$DEPS_CHECK" CUR_TOOLS="$TOOLS" CUR_THREAD="${TELEGRAM_THREAD_ID:-}"
    # Reset to detected for comparison
    BUILD_CMD="${OPT_BUILD:-$DEFAULT_BUILD}"
    TEST_CMD="${OPT_TEST:-$DEFAULT_TEST}"
    INSTALL_CMD="${OPT_INSTALL:-$DEFAULT_INSTALL}"
    DEPS_CHECK="$DEFAULT_DEPS"
    TOOLS="$DEFAULT_TOOLS"
    TELEGRAM_THREAD_ID="${OPT_THREAD:-$CUR_THREAD}"

    _update_field() {
        local label="$1" current="$2" detected="$3" varname="$4"
        if [[ "$current" == "$detected" ]]; then
            eval "$varname=\$current"
            return
        fi
        echo ""
        echo "$label:"
        echo "  current:  $current"
        echo "  detected: $detected"
        prompt KEEP "Keep current? (Y/n)" "y"
        if [[ "$KEEP" == "y" || "$KEEP" == "Y" ]]; then
            eval "$varname=\$current"
        else
            eval "$varname=\$detected"
        fi
    }

    _update_field "BUILD_CMD" "$CUR_BUILD" "$BUILD_CMD" BUILD_CMD
    _update_field "TEST_CMD" "$CUR_TEST" "$TEST_CMD" TEST_CMD
    _update_field "INSTALL_CMD" "$CUR_INSTALL" "$INSTALL_CMD" INSTALL_CMD
    _update_field "DEPS_CHECK" "$CUR_DEPS" "$DEPS_CHECK" DEPS_CHECK
    _update_field "TOOLS" "$CUR_TOOLS" "$TOOLS" TOOLS
    TOOLS_ALLOW="$TOOLS"

elif [[ "$NON_INTERACTIVE" == true ]]; then
    # Non-interactive: use detected defaults + flag overrides, no prompts
    echo "Writing config (non-interactive)..."

else
    # --- 6. Interactive: show config and ask for confirmation ---
    _show_config() {
        echo ""
        cat << EOF
  BUILD_CMD="$BUILD_CMD"
  TEST_CMD="$TEST_CMD"
  INSTALL_CMD="$INSTALL_CMD"
  DEPS_CHECK="$DEPS_CHECK"
  TOOLS="$TOOLS"
  BASE_BRANCH="$BASE_BRANCH"
  TELEGRAM_THREAD_ID="$TELEGRAM_THREAD_ID"
EOF
        echo ""
    }

    _show_config

    prompt CONFIRM "Look good? (Y/n)" "y"

    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        # Per-field edit mode
        echo ""
        prompt BUILD_CMD "Build command" "$BUILD_CMD"
        prompt TEST_CMD "Test command" "$TEST_CMD"
        prompt INSTALL_CMD "Install command" "$INSTALL_CMD"
        prompt DEPS_CHECK "Dependency check" "$DEPS_CHECK"
        prompt TOOLS "Required tools (space-separated)" "$TOOLS"
        prompt TELEGRAM_THREAD_ID "Telegram thread ID (optional)" "$TELEGRAM_THREAD_ID"
        prompt BASE_BRANCH "Base branch" "$BASE_BRANCH"
        TOOLS_ALLOW="$TOOLS"

        _show_config
        prompt CONFIRM "Look good? (Y/n)" "y"
        if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
            echo "Aborted."
            exit 0
        fi
    fi
fi

# Validate Telegram thread ID (must be numeric or empty)
if [[ -n "$TELEGRAM_THREAD_ID" ]] && [[ ! "$TELEGRAM_THREAD_ID" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Telegram thread ID must be numeric" >&2
    exit 1
fi

# Validate commands
for pair in "BUILD_CMD:Build command" "TEST_CMD:Test command" "INSTALL_CMD:Install command"; do
    var="${pair%%:*}"
    label="${pair#*:}"
    if ! validate_cmd "${!var}" "$label"; then
        exit 1
    fi
done

# Verify tools
if [[ -n "$TOOLS" ]]; then
    echo "Verifying tools..."
    local_missing=()
    for tool in $TOOLS; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo "  $tool ok"
        else
            echo "  $tool MISSING"
            local_missing+=("$tool")
        fi
    done
    if [[ ${#local_missing[@]} -gt 0 ]]; then
        echo "WARNING: ${local_missing[*]} not found in PATH. Install before running sessions."
    fi
fi

# --- 8. Write .nightcrawler/config.sh ---
mkdir -p "$PROJECT_DIR/.nightcrawler"
cat > "$PROJECT_DIR/.nightcrawler/config.sh" << CONFIGEOF
# .nightcrawler/config.sh for $PROJECT_NAME
# WARNING: Commands are executed via eval. Only edit if you trust the content.
# Generated by: nightcrawler init

BUILD_CMD="$BUILD_CMD"
TEST_CMD="$TEST_CMD"
INSTALL_CMD="$INSTALL_CMD"
DEPS_CHECK="$DEPS_CHECK"
TOOLS="$TOOLS"
TOOLS_ALLOW="$TOOLS_ALLOW"
TELEGRAM_THREAD_ID="$TELEGRAM_THREAD_ID"
CONFIGEOF
echo "Created .nightcrawler/config.sh"

# --- 9. Write .nightcrawler/CLAUDE.md scaffold (only if missing) ---
if [[ ! -f "$PROJECT_DIR/.nightcrawler/CLAUDE.md" ]]; then
    cat > "$PROJECT_DIR/.nightcrawler/CLAUDE.md" << CLAUDEEOF
# $PROJECT_NAME — Claude Code Context

## Stack
$DETECTED_STACK

## Build & Test
- Build: \`$BUILD_CMD\`
- Test: \`$TEST_CMD\`

## Rules
- Read existing source before modifying anything
- Keep changes minimal and focused
- Run build and test commands to verify before finishing
CLAUDEEOF
    echo "Created .nightcrawler/CLAUDE.md (scaffold)"
else
    echo "Skipped .nightcrawler/CLAUDE.md (already exists)"
fi

# --- 10. Upsert project in openclaw.yaml ---
if [[ -f "$YAML" ]]; then
    NC_PROJ_NAME="$PROJECT_NAME" NC_PROJ_PATH="$PROJECT_DIR" NC_PROJ_BRANCH="$BASE_BRANCH" \
    python3 - "$YAML" << 'PYEOF'
import yaml, sys, os

yaml_path = sys.argv[1]
name = os.environ['NC_PROJ_NAME']
path = os.environ['NC_PROJ_PATH']
branch = os.environ['NC_PROJ_BRANCH']

with open(yaml_path, 'r') as f:
    data = yaml.safe_load(f) or {}

if 'projects' not in data or data['projects'] is None:
    data['projects'] = {}

data['projects'][name] = {
    'path': path,
    'base_branch': branch
}

with open(yaml_path, 'w') as f:
    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
PYEOF
    echo "Updated openclaw.yaml"
else
    echo "WARNING: openclaw.yaml not found at $YAML — skipping"
fi

# --- 11. Regenerate workspace/NIGHTCRAWLER.md ---
if [[ -x "$SCRIPTS/generate-workspace.sh" ]]; then
    bash "$SCRIPTS/generate-workspace.sh"
    echo "Regenerated workspace/NIGHTCRAWLER.md"
else
    echo "NOTE: generate-workspace.sh not found — run it after creating it to update workspace commands"
fi

# --- 12. Summary ---
echo ""
echo "=== Done ==="
echo "Project: $PROJECT_NAME"
echo "Path: $PROJECT_DIR"
echo "Config: $PROJECT_DIR/.nightcrawler/config.sh"
echo ""
echo "Next: run 'start $PROJECT_NAME --budget 5' from Telegram."
