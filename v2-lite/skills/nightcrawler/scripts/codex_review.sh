#!/usr/bin/env bash
# Reviewer agent runs this. Emits NORMALIZED gate JSON on stdout.
# Cross-vendor: Codex (a different vendor) reviews Claude's change.
#
# Usage:  codex_review.sh [extra context passed to the prompt]
#
# Notes:
# - Model is intentionally NOT hardcoded (names drift). Pin it via codex config
#   or pass `-m <model>` here once you've chosen one.
# - The infra-vs-findings guard lives in adapter.py: a nonzero exit or empty
#   output becomes ran:false, NOT a rejection. Do not "fix" that here.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
skill_dir="$(cd "$here/.." && pwd)"
schema="$skill_dir/sev.schema.json"
prompt_file="$skill_dir/review-prompt.md"

# First positional arg = the directory to review (the worktree); remaining = extra context.
# No leading `cd` needed at the call site, so the whole invocation is one allowlistable command.
target_dir="${1:-$PWD}"
shift 2>/dev/null || true
if ! cd "$target_dir" 2>/dev/null; then
  # Can't enter the target -> infra failure, never a verdict (adapter emits ran:false).
  printf '' | python3 "$here/adapter.py" from-codex --exit 1
  exit 0
fi

extra="${*:-}"
prompt="$(cat "$prompt_file")"
if [ -n "$extra" ]; then
  prompt="$prompt

## Additional context for this review
$extra"
fi

# Fresh session each call (no resume) for reviewer independence.
raw="$(codex exec -s read-only --output-schema "$schema" "$prompt" 2>/tmp/nc_codex_err.log)"
status=$?

printf '%s' "$raw" | python3 "$here/adapter.py" from-codex --exit "$status"
