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

# Remove files in DST that no longer exist in SRC
for f in "$DST"/*.md; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  if [ ! -f "$SRC/$base" ]; then
    rm "$f"
    echo "  removed $base (not in repo)"
  fi
done

echo "Restarting gateway..."
openclaw gateway restart
echo "Done."
