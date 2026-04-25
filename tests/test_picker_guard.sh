#!/usr/bin/env bash
# Smoke test for the #64 picker hallucination guard.
# Validates the queue-membership grep pattern used in pick_next_task against
# a representative TASK_QUEUE.md fixture. Runs on VPS via:
#   bash /root/nightcrawler/tests/test_picker_guard.sh

set -euo pipefail

fixture=$(mktemp)
trap "rm -f '$fixture'" EXIT

cat > "$fixture" <<'EOF'
# TASK_QUEUE.md

#### NC-100 [ ] Regular queued task
Body text with NC-999 reference that must not false-match.

#### NC-101 [~] In-progress task
Body.

#### NC-102 [x] Shipped task — must not be picked
Body.

#### NC-103 [🚧] Human-only blocked task
Body.

## NC-200 [ ] Different header level — still valid
Body.

###### NC-201 [ ] Deep header level — still valid
Body.

####  NC-300  [ ]  Extra whitespace — still valid
Body.

#### NC-FOO-SMOKE [ ] Multi-segment ID
Body.
EOF

# This MUST match the regex used in scripts/nightcrawler.sh pick_next_task:
#   grep -qE "^#{1,6}[[:space:]]+${task_id}[[:space:]]+\[[ ~]\]" "$queue"
check() {
    local task_id="$1"
    local expected="$2"  # "match" or "miss"
    local actual
    if grep -qE "^#{1,6}[[:space:]]+${task_id}[[:space:]]+\[[ ~]\]" "$fixture"; then
        actual="match"
    else
        actual="miss"
    fi
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $task_id → $actual"
    else
        echo "  FAIL: $task_id → got $actual, expected $expected"
        return 1
    fi
}

fails=0

echo "Valid queued tasks (must MATCH):"
check "NC-100" match || fails=$((fails+1))
check "NC-101" match || fails=$((fails+1))
check "NC-200" match || fails=$((fails+1))
check "NC-201" match || fails=$((fails+1))
check "NC-300" match || fails=$((fails+1))
check "NC-FOO-SMOKE" match || fails=$((fails+1))

echo
echo "Ineligible tasks (must MISS):"
check "NC-102" miss || fails=$((fails+1))   # shipped [x]
check "NC-103" miss || fails=$((fails+1))   # blocked [🚧]

echo
echo "Hallucinated IDs (must MISS):"
check "NC-999" miss || fails=$((fails+1))   # appears only in body text
check "NC-429" miss || fails=$((fails+1))   # matches the live failure mode
check "NC-434" miss || fails=$((fails+1))
check "NC-ZZZ" miss || fails=$((fails+1))

echo
if (( fails > 0 )); then
    echo "FAILED: $fails assertions"
    exit 1
fi
echo "ALL PASSED ($(grep -c '^    check ' "$0" 2>/dev/null || echo '?') assertions)"

# ---------------------------------------------------------------------------
# Source the actual extract_task_context() function from nightcrawler.sh and
# call it as a bash function. Tests both happy AND miss paths through the
# real bash double-quoted python heredoc. The earlier python-body-standalone
# test missed an unescaped \" in a comment that broke bash quoting and made
# every happy-path call fail with IndentationError — surfaced by an aborted
# session on 2026-04-25 (NC-429A pick → 0-byte task_context.md → set -e die).
# ---------------------------------------------------------------------------

echo
echo "extract_task_context as sourced bash function:"

SCRIPT=/root/nightcrawler/scripts/nightcrawler.sh
[[ -f "$SCRIPT" ]] || { echo "  SKIP: $SCRIPT not present"; exit 0; }

tmp_etc=$(mktemp --suffix=.sh)
trap "rm -f '$fixture' '$tmp_etc'" EXIT
awk '/^extract_task_context\(\) \{/,/^\}$/' "$SCRIPT" > "$tmp_etc"
# Strip the function-internal `2>/dev/null` so the test surfaces python errors.
sed -i 's| 2>/dev/null$||' "$tmp_etc"

# Build a project-shaped fixture dir so $PROJECT_PATH/TASK_QUEUE.md resolves.
proj_dir=$(mktemp -d)
trap "rm -rf '$proj_dir'; rm -f '$fixture' '$tmp_etc'" EXIT
cp "$fixture" "$proj_dir/TASK_QUEUE.md"

# Happy path
set +e
out=$(PROJECT_PATH="$proj_dir" bash -c "source '$tmp_etc'; extract_task_context NC-100" 2>/tmp/etc_err.$$)
rc=$?
set -e
if (( rc != 0 )); then
    echo "  FAIL: happy path NC-100 exited $rc (stderr: $(cat /tmp/etc_err.$$))"
    rm -f /tmp/etc_err.$$
    exit 1
fi
if [[ -z "$out" ]]; then
    echo "  FAIL: happy path produced empty stdout"
    rm -f /tmp/etc_err.$$
    exit 1
fi
echo "  PASS: happy path NC-100 → exit 0, ${#out} chars stdout"

# Multi-segment ID happy path (this is the shape that aborted the live session)
set +e
out=$(PROJECT_PATH="$proj_dir" bash -c "source '$tmp_etc'; extract_task_context NC-FOO-SMOKE" 2>/tmp/etc_err.$$)
rc=$?
set -e
if (( rc != 0 )) || [[ -z "$out" ]]; then
    echo "  FAIL: multi-segment NC-FOO-SMOKE exited $rc, ${#out} chars (stderr: $(cat /tmp/etc_err.$$))"
    rm -f /tmp/etc_err.$$
    exit 1
fi
echo "  PASS: multi-segment NC-FOO-SMOKE → exit 0, ${#out} chars stdout"

# Miss path
set +e
out=$(PROJECT_PATH="$proj_dir" bash -c "source '$tmp_etc'; extract_task_context NC-DOES-NOT-EXIST" 2>/tmp/etc_err.$$)
rc=$?
set -e
if (( rc != 1 )); then
    echo "  FAIL: miss path expected exit 1, got $rc"
    rm -f /tmp/etc_err.$$
    exit 1
fi
if [[ -n "$out" ]]; then
    echo "  FAIL: miss path stdout should be empty, got: $out"
    rm -f /tmp/etc_err.$$
    exit 1
fi
if ! grep -q 'not found in TASK_QUEUE.md' /tmp/etc_err.$$; then
    echo "  FAIL: miss path stderr missing expected message (got: $(cat /tmp/etc_err.$$))"
    rm -f /tmp/etc_err.$$
    exit 1
fi
echo "  PASS: miss path → exit 1, empty stdout, loud stderr"
rm -f /tmp/etc_err.$$

echo
echo "OK"
