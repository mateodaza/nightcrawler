#!/usr/bin/env bash
# nightcrawler-setup.sh — VPS bootstrap for Nightcrawler.
# Checks prerequisites, configures API keys, installs CLIs, sets up OpenClaw.
# Idempotent — safe to run multiple times.
#
# Usage: ./scripts/nightcrawler-setup.sh

set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
NC_ROOT="$(dirname "$SCRIPTS")"
ENV_FILE="$HOME/.env"

# --- Helpers ---

_check() {
    local label="$1" cmd="$2"
    if command -v "$cmd" >/dev/null 2>&1; then
        local ver
        ver=$("$cmd" --version 2>&1 | head -1) || ver="installed"
        echo "  $label ok ($ver)"
        return 0
    else
        echo "  $label MISSING"
        return 1
    fi
}

_env_has() {
    local key="$1"
    [[ -f "$ENV_FILE" ]] && grep -q "^${key}=" "$ENV_FILE"
}

_env_get() {
    local key="$1"
    [[ -f "$ENV_FILE" ]] && grep "^${key}=" "$ENV_FILE" | head -1 | cut -d= -f2- | sed 's/^"//;s/"$//'
}

_env_set() {
    local key="$1" value="$2"
    if _env_has "$key"; then
        # Update existing
        sed -i.bak "s|^${key}=.*|${key}=\"${value}\"|" "$ENV_FILE"
        rm -f "$ENV_FILE.bak"
    else
        echo "${key}=\"${value}\"" >> "$ENV_FILE"
    fi
}

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

_prompt_value() {
    local label="$1" default="${2:-}"
    local input
    if [[ -n "$default" ]]; then
        printf "%s [%s]: " "$label" "$default" >&2
    else
        printf "%s: " "$label" >&2
    fi
    read -r input
    echo "${input:-$default}"
}

# --- Start ---

echo "Nightcrawler — VPS Setup"
echo ""

# --- Step 1: Prerequisites ---
echo "Checking prerequisites..."
PREREQ_OK=true

_check "git" "git" || PREREQ_OK=false
_check "python3" "python3" || { echo "    Install: apt install python3 (or your package manager)"; PREREQ_OK=false; }
_check "node" "node" || { echo "    Install: https://nodejs.org/ or use nvm"; PREREQ_OK=false; }
_check "npm" "npm" || PREREQ_OK=false

# Check PyYAML
if python3 -c "import yaml" 2>/dev/null; then
    echo "  PyYAML ok"
else
    echo "  PyYAML MISSING"
    echo "    Install: pip install pyyaml"
    PREREQ_OK=false
fi

if [[ "$PREREQ_OK" != true ]]; then
    echo ""
    echo "Install missing prerequisites above, then re-run this script."
    exit 1
fi
echo ""

# --- Step 2: API Keys ---
echo "Step 2/5: API Keys"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

if _env_has "ANTHROPIC_API_KEY"; then
    echo "  ANTHROPIC_API_KEY ok (already set)"
else
    val=$(_prompt_value "ANTHROPIC_API_KEY (or 'skip')" "skip")
    if [[ "$val" != "skip" && -n "$val" ]]; then
        _env_set "ANTHROPIC_API_KEY" "$val"
        echo "  Saved to $ENV_FILE"
    else
        echo "  Skipped — add manually to $ENV_FILE later"
    fi
fi

if _env_has "OPENAI_API_KEY"; then
    echo "  OPENAI_API_KEY ok (already set)"
else
    val=$(_prompt_value "OPENAI_API_KEY (or 'skip')" "skip")
    if [[ "$val" != "skip" && -n "$val" ]]; then
        _env_set "OPENAI_API_KEY" "$val"
        echo "  Saved to $ENV_FILE"
    else
        echo "  Skipped — add manually to $ENV_FILE later"
    fi
fi
echo ""

# --- Step 3: Claude Code CLI ---
echo "Step 3/5: Claude Code CLI"
if command -v claude >/dev/null 2>&1; then
    echo "  claude ok ($(claude --version 2>&1 | head -1))"
else
    echo "  claude MISSING"
    echo "  Install: npm install -g @anthropic-ai/claude-code"
    echo "  Then: claude login"
fi
echo ""

# --- Step 4: Codex CLI ---
echo "Step 4/5: Codex CLI"
if command -v codex >/dev/null 2>&1; then
    echo "  codex ok ($(codex --version 2>&1 | head -1))"
else
    echo "  codex MISSING"
    echo "  Install: npm install -g @openai/codex"
fi
echo ""

# --- Step 5: Telegram Bot ---
echo "Step 5/5: Telegram Bot"
if _env_has "TELEGRAM_BOT_TOKEN" && _env_has "TELEGRAM_CHAT_ID"; then
    echo "  TELEGRAM_BOT_TOKEN ok (already set)"
    echo "  TELEGRAM_CHAT_ID ok (already set)"
else
    if ! _env_has "TELEGRAM_BOT_TOKEN"; then
        val=$(_prompt_value "TELEGRAM_BOT_TOKEN (or 'skip')" "skip")
        if [[ "$val" != "skip" && -n "$val" ]]; then
            _env_set "TELEGRAM_BOT_TOKEN" "$val"
        fi
    fi
    if ! _env_has "TELEGRAM_CHAT_ID"; then
        val=$(_prompt_value "TELEGRAM_CHAT_ID (or 'skip')" "skip")
        if [[ "$val" != "skip" && -n "$val" ]]; then
            _env_set "TELEGRAM_CHAT_ID" "$val"
        fi
    fi

    # Send test message if both are set
    if _env_has "TELEGRAM_BOT_TOKEN" && _env_has "TELEGRAM_CHAT_ID"; then
        token=$(_env_get "TELEGRAM_BOT_TOKEN")
        chat=$(_env_get "TELEGRAM_CHAT_ID")
        echo "  Sending test message..."
        response=$(curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
            -d chat_id="$chat" \
            -d text="Nightcrawler connected" 2>&1) || true
        if echo "$response" | python3 -c "import sys,json; sys.exit(0 if json.load(sys.stdin).get('ok') else 1)" 2>/dev/null; then
            echo "  Test message sent ok"
        else
            echo "  WARNING: Test message failed. Check token and chat ID."
        fi
    fi
fi
echo ""

# --- Step 6: OpenClaw (optional) ---
echo "Step 6: OpenClaw (optional — needed for Telegram dispatch)"
if command -v openclaw >/dev/null 2>&1; then
    echo "  openclaw ok ($(openclaw --version 2>&1 | head -1))"

    DEPLOY_CONFIRM=$(_prompt_value "Deploy workspace files? (Y/n)" "y")
    if [[ "$DEPLOY_CONFIRM" == "y" || "$DEPLOY_CONFIRM" == "Y" ]]; then
        mkdir -p "$HOME/.openclaw/workspace"
        cp "$NC_ROOT/workspace/"*.md "$HOME/.openclaw/workspace/"
        echo "  Deployed $(ls "$NC_ROOT/workspace/"*.md | wc -l | tr -d ' ') workspace files"
    fi

    # Systemd service
    _generate_systemd_unit() {
        local node_bin openclaw_bin
        node_bin=$(command -v node) || { echo "ERROR: node not found in PATH"; return 1; }
        openclaw_bin=$(command -v openclaw) || { echo "ERROR: openclaw not found in PATH"; return 1; }

        cat << UNIT
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
UNIT
    }

    _install_systemd_service() {
        local unit_file="/etc/systemd/system/openclaw-gateway.service"

        if _needs_sudo; then
            if ! command -v sudo >/dev/null 2>&1; then
                echo "  WARNING: Not running as root and 'sudo' not found."
                echo "  To set up the service manually, save this as $unit_file:"
                echo ""
                _generate_systemd_unit
                echo ""
                echo "  Then: systemctl daemon-reload && systemctl enable --now openclaw-gateway"
                return 1
            fi
            echo "  Systemd setup requires root. You may be prompted for your password."
        fi

        _generate_systemd_unit | _run_privileged tee "$unit_file" > /dev/null
        _run_privileged systemctl daemon-reload
        _run_privileged systemctl enable --now openclaw-gateway
        echo "  OpenClaw gateway service installed and started"
    }

    SERVICE_CONFIRM=$(_prompt_value "Set up systemd service? (Y/n)" "y")
    if [[ "$SERVICE_CONFIRM" == "y" || "$SERVICE_CONFIRM" == "Y" ]]; then
        _install_systemd_service || echo "  Skipping service install (manual step required)"
    fi
else
    echo "  openclaw not found"
    echo "  Install: npm install -g openclaw"
    echo "  Nightcrawler works without it (just no Telegram dispatch)."
fi
echo ""

# --- Summary ---
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Run 'nightcrawler init' in your project directory"
echo "  2. Start a session: 'start <project> --budget 5' from Telegram"
echo ""
echo "If you skipped any steps, edit $ENV_FILE and re-run this script."
