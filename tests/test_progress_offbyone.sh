#!/usr/bin/env bash
# Smoke test for PROGRESS.md hash-drop fix.
#
# Background: append_to_progress used to record the short HEAD hash on each
# row, but it ran PRE-commit so the hash was always the parent of the actual
# task commit (off-by-one verified across NC-421..427 in the production
# camello/PROGRESS.md). Attempting to fix this in-place via post-commit sed +
# git commit --amend doesn't work because amending changes the commit's own
# hash, leaving PROGRESS.md pointing at an orphaned (pre-amend) commit.
#
# Fix shipped: drop the hash field entirely. Row shape becomes:
#     - **NC-100** — 2026-04-25 — Session: 20260425-test
# Commit lookup is via `git log --grep=NC-XXX` (canonical and unaffected).
#
# Runs on VPS via: bash /root/nightcrawler/tests/test_progress_offbyone.sh

set -euo pipefail

SCRIPT=/root/nightcrawler/scripts/nightcrawler.sh
[[ -f "$SCRIPT" ]] || { echo "missing $SCRIPT"; exit 2; }

# ---------------------------------------------------------------------------
# Source append_to_progress and call it. Verify the produced row has no
# backtick-wrapped hash field (the field that was structurally one-off).
# ---------------------------------------------------------------------------

tmp_fn=$(mktemp --suffix=.sh)
proj=$(mktemp -d)
trap "rm -f '$tmp_fn'; rm -rf '$proj'" EXIT

awk '/^append_to_progress\(\) \{/,/^\}$/' "$SCRIPT" > "$tmp_fn"
touch "$proj/PROGRESS.md"

fails=0

# Case 1: clean call, no degraded note
PROJECT_PATH="$proj" SESSION_ID="20260425-test" bash -c "source '$tmp_fn'; append_to_progress NC-100"
row=$(cat "$proj/PROGRESS.md")

if [[ "$row" =~ \`[^\`]+\` ]]; then
    echo "FAIL: row still contains backtick-wrapped field (should be hash-free): $row"
    fails=$((fails+1))
else
    echo "PASS: row has no backtick field"
fi

if [[ "$row" == *"NC-100"* && "$row" == *"20260425-test"* && "$row" == *"$(date -u +%F)"* ]]; then
    echo "PASS: row contains task_id, session, and date"
else
    echo "FAIL: row missing expected fields. got: $row"
    fails=$((fails+1))
fi

# Case 2: degraded-note variant — preserves the warning suffix
> "$proj/PROGRESS.md"
PROJECT_PATH="$proj" SESSION_ID="20260425-test" bash -c "source '$tmp_fn'; append_to_progress NC-101 'soft-rejected after 3 rounds'"
row=$(cat "$proj/PROGRESS.md")

if [[ "$row" == *"⚠"* && "$row" == *"soft-rejected after 3 rounds"* ]]; then
    echo "PASS: degraded-note variant preserves warning suffix"
else
    echo "FAIL: degraded-note suffix missing. got: $row"
    fails=$((fails+1))
fi

if [[ "$row" =~ \`[^\`]+\` ]]; then
    echo "FAIL: degraded-note row still contains backtick field: $row"
    fails=$((fails+1))
else
    echo "PASS: degraded-note row also hash-free"
fi

# Case 3: end-to-end — git log --grep=NC-XXX is the canonical lookup and is
# unaffected by the row-format change.
repo=$(mktemp -d)
trap "rm -f '$tmp_fn'; rm -rf '$proj' '$repo'" EXIT
cd "$repo"
git init -q
git config user.email test@example.com
git config user.name test
echo init > README; git add -A; git commit -q -m initial

echo code > app.txt
git add -A
git commit -q -m "[nightcrawler] feat(NC-200): test task

Nightcrawler-Task: NC-200"

found_hash=$(git log --grep='NC-200' --format=%h | head -1)
real_hash=$(git rev-parse --short HEAD)
if [[ "$found_hash" == "$real_hash" ]]; then
    echo "PASS: git log --grep=NC-200 returns the actual commit hash ($real_hash)"
else
    echo "FAIL: git log --grep=NC-200 returned $found_hash, expected $real_hash"
    fails=$((fails+1))
fi

echo
if (( fails > 0 )); then
    echo "FAILED: $fails assertions"
    exit 1
fi
echo "OK"
