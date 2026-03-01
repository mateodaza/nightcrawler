#!/usr/bin/env bash
# Deploy workspace files from nightcrawler repo to OpenClaw workspace.
# Usage: bash ~/nightcrawler/scripts/deploy-workspace.sh

set -euo pipefail

SRC="$HOME/nightcrawler/workspace"
DST="$HOME/.openclaw/workspace"

if [ ! -d "$SRC" ]; then
  echo "ERROR: $SRC not found" >&2
  exit 1
fi

for f in "$SRC"/*.md; do
  [ -f "$f" ] || continue
  cp "$f" "$DST/"
  echo "  copied $(basename "$f")"
done

# Note: we only overwrite files that exist in SRC.
# OpenClaw's own files (AGENTS.md, TOOLS.md, etc.) are left untouched.

echo "Restarting gateway..."
openclaw gateway restart
echo "Done."
