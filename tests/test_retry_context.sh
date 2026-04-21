#!/usr/bin/env bash
# Smoke test for write_retry_context / _retry_section_body.
# Reproduces the NC-402 failure mode: build fails with a TS2345 error while
# test phase emits ~200 lines of passing output. Previous tail-200 artifact
# captured only test output; new split-section artifact must surface the build
# error first.
#
# Runs on VPS via: bash test_retry_context.sh

set -euo pipefail

SCRIPT=/root/nightcrawler/scripts/nightcrawler.sh
[[ -f "$SCRIPT" ]] || { echo "missing $SCRIPT"; exit 2; }

# Extract just the three helper functions we need into a temp file so we can
# source them without triggering nightcrawler's top-level initialization.
tmp_helpers=$(mktemp)
awk '
    /^retry_verify_context_path\(\) \{/       { p=1 }
    /^_retry_section_body\(\) \{/             { p=1 }
    /^write_retry_context\(\) \{/             { p=1 }
    p { print }
    p && /^\}$/                               { p=0; print "" }
' "$SCRIPT" > "$tmp_helpers"

# Sanity: we expect all three functions in the extract.
for fn in retry_verify_context_path _retry_section_body write_retry_context; do
    grep -q "^${fn}()" "$tmp_helpers" || { echo "FAIL: helper $fn not extracted"; exit 3; }
done

# shellcheck disable=SC1090
source "$tmp_helpers"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir" "$tmp_helpers"' EXIT

build_log="$workdir/build.log"
test_log="$workdir/test.log"
retry_ctx="$workdir/verify_retry_context.md"

# Craft a realistic-ish failing pnpm build log. TS2345 buried ~20 lines in.
{
    echo "> camello-web@0.1.0 build"
    echo "> next build"
    for i in $(seq 1 15); do echo "[info] compiling module $i..."; done
    echo "./src/features/expenses/expense-section.tsx:188:7"
    echo "Type error: Argument of type '{ onOpenChange: (open: boolean) => void; }' is not assignable to parameter of type 'ExpenseDialogProps'."
    echo "  Types of property 'onOpenChange' are incompatible."
    echo "error TS2345: Argument of type X is not assignable to parameter of type Y."
    echo ""
    echo "ELIFECYCLE  Command failed with exit code 1."
} > "$build_log"

# Craft a noisy passing test log: 200 lines of Jest-style PASS output. Bigger
# than 7KB so the old tail-c 7000 approach would have dropped the build error
# entirely if we had used a combined-log tail.
{
    echo "> camello-web@0.1.0 test"
    echo "> vitest run"
    for i in $(seq 1 200); do
        echo "PASS  src/features/test_case_${i}.test.ts (some realistic filler to pad out the line, so each row is not trivially short) > passes"
    done
    echo ""
    echo "Test Files  42 passed (42)"
    echo "     Tests  200 passed (200)"
} > "$test_log"

# Sanity-check sizes so we know we're really exercising the cap.
build_size=$(wc -c < "$build_log")
test_size=$(wc -c < "$test_log")
echo "build_log=${build_size}B  test_log=${test_size}B"
(( test_size > 7000 )) || { echo "FAIL: test_log too small to exercise cap"; exit 4; }

# Invoke writer — build failed (exit 1), test passed (exit 0).
write_retry_context "$retry_ctx" "NC-TEST" "abcdef1234" 1 \
    "$build_log" 1 \
    "$test_log"  0

# Assertions.
echo "--- retry_ctx ($(wc -c < "$retry_ctx") bytes) ---"
cat "$retry_ctx"
echo "--- assertions ---"

fail=0
assert() { if eval "$1"; then echo "OK  : $2"; else echo "FAIL: $2"; fail=1; fi; }

# 1. Build section exists and is marked failed.
assert "grep -q '^## build (failed, exit 1)' \"$retry_ctx\"" "build section marked failed"
# 2. Test section exists and is marked passed.
assert "grep -q '^## test (passed, exit 0)' \"$retry_ctx\"" "test section marked passed"
# 3. Build section appears BEFORE test section (failed phase on top).
build_line=$(grep -n '^## build' "$retry_ctx" | head -1 | cut -d: -f1)
test_line=$(grep -n '^## test'  "$retry_ctx" | head -1 | cut -d: -f1)
assert "[[ $build_line -lt $test_line ]]" "build section precedes test section ($build_line < $test_line)"
# 4. TS2345 surfaces in the artifact (diagnostic grep or tail).
assert "grep -q 'TS2345' \"$retry_ctx\"" "TS2345 visible in retry-context"
# 5. Diagnostic block appears in build section.
assert "grep -q '^Diagnostic lines:' \"$retry_ctx\"" "diagnostic block present"
# 6. Artifact total stays in a reasonable size envelope (<= 12KB).
size=$(wc -c < "$retry_ctx")
assert "(( size <= 12288 ))" "artifact size $size <= 12KB"
# 7. Passing-section body still included (so implementer sees what did pass).
assert "grep -q 'PASS  src/features/test_case_' \"$retry_ctx\"" "passing test output retained"
# 8. Header recorded both exits.
assert "grep -q 'Build exit: 1. Test exit: 0.' \"$retry_ctx\"" "header has both exit codes"

if (( fail == 0 )); then
    echo "--- SMOKE OK ---"
else
    echo "--- SMOKE FAILED ---"
    exit 1
fi

# =========================================================================
# Second scenario: both build and test fail. Verify build goes first AND
# both sections marked failed.
# =========================================================================
echo
echo "=== scenario 2: both failed ==="
retry_ctx2="$workdir/verify_retry_context_2.md"
test_log2="$workdir/test2.log"
{
    echo "> camello-web@0.1.0 test"
    for i in $(seq 1 50); do echo "PASS  test_${i}.test.ts"; done
    echo "FAIL  src/features/expenses/expense-section.test.ts"
    echo "  Expected true, got false"
    echo "Test Files  1 failed (1)"
} > "$test_log2"

write_retry_context "$retry_ctx2" "NC-TEST2" "deadbeef01" 2 \
    "$build_log" 1 \
    "$test_log2" 1

assert "grep -q '^## build (failed, exit 1)' \"$retry_ctx2\"" "s2: build section failed"
assert "grep -q '^## test (failed, exit 1)' \"$retry_ctx2\"" "s2: test section failed"
build_line=$(grep -n '^## build' "$retry_ctx2" | head -1 | cut -d: -f1)
test_line=$(grep -n '^## test'  "$retry_ctx2" | head -1 | cut -d: -f1)
assert "[[ $build_line -lt $test_line ]]" "s2: build precedes test"
assert "grep -q 'FAIL  src/features' \"$retry_ctx2\"" "s2: test FAIL line captured"
assert "grep -q 'TS2345' \"$retry_ctx2\"" "s2: TS2345 still surfaced"

if (( fail == 0 )); then
    echo "--- ALL SMOKE TESTS PASSED ---"
else
    echo "--- SMOKE TESTS FAILED ---"
    exit 1
fi
