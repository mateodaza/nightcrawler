#!/bin/bash
# Setup script for Clout project on Nightcrawler VPS
# Run as root from the nightcrawler repo:
#   bash scripts/setup-clout.sh
#
# Prerequisites: git clone this repo to /home/nightcrawler/nightcrawler first
# After running: fill in /home/nightcrawler/.env with your API keys

set -euo pipefail

NC_HOME="/home/nightcrawler"

echo "=== Nightcrawler + Clout VPS Setup ==="
echo ""

# --- 1. User ---
if ! id nightcrawler &>/dev/null; then
    adduser --disabled-password --gecos "" nightcrawler
    echo "[✓] Created nightcrawler user"
else
    echo "[·] nightcrawler user exists"
fi

# --- 2. Directory structure ---
sudo -u nightcrawler mkdir -p $NC_HOME/nightcrawler/sessions
sudo -u nightcrawler mkdir -p $NC_HOME/projects
echo "[✓] Directories ready"

# --- 3. Clone clout repo ---
if [ ! -d $NC_HOME/projects/clout/.git ]; then
    sudo -u nightcrawler git clone https://github.com/mateodaza/clout.git $NC_HOME/projects/clout
    echo "[✓] Cloned clout repo"
else
    cd $NC_HOME/projects/clout
    sudo -u nightcrawler git pull --ff-only || echo "[!] Could not pull clout — check manually"
    echo "[·] clout repo exists, pulled latest"
fi

sudo -u nightcrawler git -C $NC_HOME/projects/clout config user.name "Nightcrawler"
sudo -u nightcrawler git -C $NC_HOME/projects/clout config user.email "nightcrawler@local"

# --- 4. System dependencies ---
apt-get update -qq

if ! command -v podman &>/dev/null; then
    apt-get install -y -qq podman
    echo "[✓] Installed podman"
else
    echo "[·] podman $(podman --version | awk '{print $3}')"
fi

if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y -qq nodejs
    npm install -g pnpm
    echo "[✓] Installed node $(node --version) + pnpm"
else
    echo "[·] node $(node --version)"
fi

# --- 5. Foundry ---
if sudo -u nightcrawler bash -c '$HOME/.foundry/bin/forge --version' &>/dev/null; then
    echo "[·] foundry $(sudo -u nightcrawler bash -c '$HOME/.foundry/bin/forge --version 2>/dev/null' | head -1)"
else
    sudo -u nightcrawler bash -c 'curl -L https://foundry.paradigm.xyz | bash'
    sudo -u nightcrawler bash -c '$HOME/.foundry/bin/foundryup'
    echo "[✓] Installed foundry"
fi

# Add foundry to nightcrawler PATH if not already there
if ! sudo -u nightcrawler grep -q '.foundry/bin' $NC_HOME/.profile 2>/dev/null; then
    echo 'export PATH="$HOME/.foundry/bin:$PATH"' | sudo -u nightcrawler tee -a $NC_HOME/.profile > /dev/null
    echo "[✓] Added foundry to PATH"
fi

# --- 6. .env ---
if [ ! -f $NC_HOME/.env ]; then
    cat > $NC_HOME/.env <<'ENV'
# Nightcrawler — fill in your keys
ANTHROPIC_API_KEY=
OPENAI_API_KEY=
TWILIO_ACCOUNT_SID=
TWILIO_AUTH_TOKEN=
TWILIO_WHATSAPP_FROM=whatsapp:+
TWILIO_WHATSAPP_TO=whatsapp:+
ENV
    chown nightcrawler:nightcrawler $NC_HOME/.env
    chmod 600 $NC_HOME/.env
    echo "[✓] Created .env template"
else
    echo "[·] .env exists"
fi

# --- 7. Ownership ---
chown -R nightcrawler:nightcrawler $NC_HOME/
echo "[✓] Ownership fixed"

# --- 8. Validate ---
echo ""
echo "=== Validation ==="
echo "Nightcrawler docs: $(ls $NC_HOME/nightcrawler/*.md 2>/dev/null | wc -l) files"
echo "Nightcrawler config: $(ls $NC_HOME/nightcrawler/config/*.yaml 2>/dev/null | wc -l) files"
echo "Clout docs: $(ls $NC_HOME/projects/clout/*.md 2>/dev/null | wc -l) files"
echo ""

# Check .env filled
if grep -q "ANTHROPIC_API_KEY=$" $NC_HOME/.env 2>/dev/null; then
    echo "⚠️  API keys empty → nano $NC_HOME/.env"
else
    echo "✓ .env has values"
fi

echo ""
echo "=== Done ==="
echo "Next: nano $NC_HOME/.env (fill API keys)"
echo "Then: sudo -u nightcrawler bash -c 'source ~/.profile && forge --version'"
