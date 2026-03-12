#!/usr/bin/env bash
# Deploy workspace files from nightcrawler repo to OpenClaw workspace.
# Substitutes __NC_SCRIPTS__ and __NC_STATE_DIR__ placeholders with the actual
# paths for this machine so exec commands work correctly.
#
# Usage: bash ~/nightcrawler/scripts/deploy-workspace.sh

set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
SRC="$(dirname "$SCRIPTS")/workspace"
DST="$HOME/.openclaw/workspace"

# Compute runtime paths for this machine
NC_SCRIPTS="$SCRIPTS"
NC_STATE_DIR="${NIGHTCRAWLER_STATE_PATH:-$HOME/.nightcrawler}"

if [ ! -d "$SRC" ]; then
  echo "ERROR: $SRC not found" >&2
  exit 1
fi

mkdir -p "$DST"

for f in "$SRC"/*.md; do
  [ -f "$f" ] || continue
  dest="$DST/$(basename "$f")"
  # Substitute placeholders before copying
  NC_SCRIPTS_ESC="${NC_SCRIPTS//|/\\|}"
  NC_STATE_DIR_ESC="${NC_STATE_DIR//|/\\|}"
  sed "s|__NC_SCRIPTS__|${NC_SCRIPTS_ESC}|g; s|__NC_STATE_DIR__|${NC_STATE_DIR_ESC}|g" \
      "$f" > "$dest"
  echo "  deployed $(basename "$f")"
done

# Note: we only overwrite files that exist in SRC.
# OpenClaw's own files (AGENTS.md, TOOLS.md, etc.) are left untouched.

echo "Restarting gateway..."
openclaw gateway restart
echo "Done."
