#!/usr/bin/env bash
# Install (or verify) the Nightcrawler v2-lite skill + workflow into ~/.claude.
#
# COPY, not symlink, on purpose: the gate must be FROZEN between deliberate installs
# (spec §12) — never live-edited from the repo while a run is driving.
#
#   ./install.sh            install skill + workflow, then print the freeze-check shasums
#   ./install.sh --check     report drift between repo source and installed copies
#                            (exit 0 = in sync, exit 1 = drifted / not installed)
#
# Run --check before any auto-mode / feat run so you never run a stale gate.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"           # .../v2-lite
SKILL_SRC="$here/skills/nightcrawler"
WF_SRC="$here/workflows/nightcrawler-loop.workflow.js"
SKILL_DST="$HOME/.claude/skills/nightcrawler"
WF_DST="$HOME/.claude/workflows/nightcrawler-loop.workflow.js"

# Ignore Python/pytest caches — they're build artifacts, not part of the gate.
EXCL=(--exclude=__pycache__ --exclude=.pytest_cache --exclude='pytest-cache-files-*' --exclude='*.pyc')

check() {
  local drift=0
  if diff -rq "${EXCL[@]}" "$SKILL_SRC" "$SKILL_DST" >/dev/null 2>&1; then
    echo "ok:    skill in sync"
  else
    echo "DRIFT: skill differs from source (or not installed)"; drift=1
  fi
  if diff -q "$WF_SRC" "$WF_DST" >/dev/null 2>&1; then
    echo "ok:    workflow in sync"
  else
    echo "DRIFT: workflow differs from source (or not installed)"; drift=1
  fi
  return $drift
}

if [[ "${1:-}" == "--env-check" ]]; then
  # Preflight: is the target repo runnable (node version / deps / verifier toolchain)?
  # Run before a feat/auto run so verify never false-fails on a setup issue. Defaults to $PWD.
  exec python3 "$here/skills/nightcrawler/scripts/env_check.py" "${2:-$PWD}"
fi

if [[ "${1:-}" == "--auto-setup" ]]; then
  # OPT-IN: add the review-egress trust line to ~/.claude/settings.json so the loop's
  # Codex review runs under auto mode without per-run approval. Structured JSON merge —
  # preserves every existing setting, backs up first, idempotent. (See merge_settings.py.)
  exec python3 "$here/merge_settings.py" --apply
fi

if [[ "${1:-}" == "--check" ]]; then
  rc=0
  check || rc=1
  # auto-mode trust is opt-in; report its status but don't fail the drift check on it
  python3 "$here/merge_settings.py" --check || true
  if [[ $rc -eq 0 ]]; then
    echo "installed == source (frozen, in sync)"
  else
    echo "-> run ./install.sh to re-sync BEFORE your next run"
    exit 1
  fi
  exit 0
fi

mkdir -p "$HOME/.claude/skills" "$HOME/.claude/workflows"
rm -rf "$SKILL_DST"
cp -r "$SKILL_SRC" "$SKILL_DST"
# prune copied caches so the installed gate is clean
find "$SKILL_DST" -type d \( -name __pycache__ -o -name '.pytest_cache' -o -name 'pytest-cache-files-*' \) -prune -exec rm -rf {} + 2>/dev/null || true
cp "$WF_SRC" "$WF_DST"

echo "installed skill    -> $SKILL_DST"
echo "installed workflow -> $WF_DST"
echo
echo "freeze-check (shasum of installed gate scripts):"
shasum "$SKILL_DST"/scripts/*.py "$SKILL_DST"/scripts/*.sh
