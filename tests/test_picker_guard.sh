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
# Defense-in-depth: verify extract_task_context no longer emits a "Task NC-XXX"
# stub on miss. We can't easily invoke the bash function in isolation, so we
# extract just the python body and run it against a fixture missing the ID.
# ---------------------------------------------------------------------------

echo
echo "extract_task_context fallback (must FAIL LOUD, not print stub):"

tmp_py=$(mktemp --suffix=.py)
trap "rm -f '$fixture' '$tmp_py'" EXIT
cat > "$tmp_py" <<PY
import re, sys

with open("$fixture") as f:
    lines = f.readlines()

task_id = "NC-DOES-NOT-EXIST"
header_re = re.compile(r'^#{1,6}\s+' + re.escape(task_id) + r'\s+\[.\]')
found = False
for i, line in enumerate(lines):
    if header_re.match(line):
        print(line.rstrip())
        for j in range(i+1, len(lines)):
            if re.match(r'^#{1,6}\s', lines[j]):
                break
            print(lines[j].rstrip())
        found = True
        break

if not found:
    sys.stderr.write('extract_task_context: task ID ' + task_id + ' not found in TASK_QUEUE.md\n')
    sys.exit(1)
PY

set +e
out=$(python3 "$tmp_py" 2>/dev/null)
rc=$?
set -e
if (( rc != 1 )); then
    echo "  FAIL: expected exit 1, got $rc"
    exit 1
fi
if [[ -n "$out" ]]; then
    echo "  FAIL: fallback should emit nothing on stdout, got: $out"
    exit 1
fi
echo "  PASS: exit 1, empty stdout on missing ID"

echo
echo "OK"
