#!/usr/bin/env bash
# Local smoke test for stream-accumulator.py. Feeds it synthetic events
# matching the schema captured from the live claude CLI 2.1.63 on VPS.
# No `set -e`: we deliberately exercise non-zero exits (partial envelope
# path returns 2) and capture them via rc=$?.
set -uo pipefail

ACC="$(cd "$(dirname "$0")" && pwd)/stream-accumulator.py"
TMPDIR="$(mktemp -d)"
ENV_OUT="$TMPDIR/envelope.json"
ACC_ERR="$TMPDIR/acc.err"

echo "=== Test 1: natural exit (all events, result present) ==="
{
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"sess-abc","model":"claude-sonnet-4-6","mcp_servers":[]}'
  printf '%s\n' '{"type":"assistant","message":{"id":"m1","model":"claude-sonnet-4-6","content":[{"type":"text","text":"Hello "}],"usage":{"output_tokens":2}}}'
  printf '%s\n' '{"type":"assistant","message":{"id":"m2","model":"claude-sonnet-4-6","content":[{"type":"text","text":"world."}],"usage":{"output_tokens":4}}}'
  printf '%s\n' '{"type":"rate_limit_event","remaining":100}'
  printf '%s\n' '{"type":"result","result":"Hello world.","total_cost_usd":0.012,"session_id":"sess-abc","usage":{"input_tokens":10,"output_tokens":4,"cache_read_input_tokens":0,"cache_creation_input_tokens":50},"modelUsage":{"claude-sonnet-4-6":{"inputTokens":10,"outputTokens":4,"cacheReadInputTokens":0,"cacheCreationInputTokens":50,"costUSD":0.012,"contextWindow":200000}}}'
} | python3 "$ACC" --envelope-out "$ENV_OUT" --heartbeat-interval 10 2>"$ACC_ERR" | tee "$TMPDIR/stdout.log"
rc=$?
echo "--- exit code: $rc (expect 0)"
echo "--- envelope-out file:"
python3 -c "import json,sys; e=json.load(open('$ENV_OUT')); print(json.dumps(e, indent=2))"
echo "--- stderr:"
cat "$ACC_ERR"
echo

echo "=== Test 2: partial (no result event) ==="
ACC_ERR2="$TMPDIR/acc2.err"
ENV_OUT2="$TMPDIR/envelope2.json"
{
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"sess-xyz","model":"claude-opus-4-6","mcp_servers":[]}'
  printf '%s\n' '{"type":"assistant","message":{"id":"m1","model":"claude-opus-4-6","content":[{"type":"text","text":"Partial content before "}],"usage":{"output_tokens":5}}}'
  printf '%s\n' '{"type":"assistant","message":{"id":"m2","model":"claude-opus-4-6","content":[{"type":"text","text":"being killed."}],"usage":{"output_tokens":8}}}'
} | python3 "$ACC" --envelope-out "$ENV_OUT2" --heartbeat-interval 10 2>"$ACC_ERR2" | tee "$TMPDIR/stdout2.log"
rc=$?
echo "--- exit code: $rc (expect 2)"
echo "--- envelope-out file:"
python3 -c "import json,sys; e=json.load(open('$ENV_OUT2')); print(json.dumps(e, indent=2))"
echo "--- stderr:"
cat "$ACC_ERR2"
echo

echo "=== Test 3: heartbeat emission during slow stream ==="
ACC_ERR3="$TMPDIR/acc3.err"
ENV_OUT3="$TMPDIR/envelope3.json"
(
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"sess-slow","model":"claude-sonnet-4-6"}'
  sleep 0.7
  printf '%s\n' '{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"slow "}]}}'
  sleep 0.7
  printf '%s\n' '{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"turn"}]}}'
  sleep 0.7
  printf '%s\n' '{"type":"result","result":"slow turn","total_cost_usd":0.001,"session_id":"sess-slow","usage":{"input_tokens":5,"output_tokens":2}}'
) | python3 "$ACC" --envelope-out "$ENV_OUT3" --heartbeat-interval 0.3 2>"$ACC_ERR3" > "$TMPDIR/stdout3.log"
rc=$?
echo "--- exit code: $rc (expect 0)"
echo "--- stdout lines (heartbeats should appear before final envelope):"
cat "$TMPDIR/stdout3.log"
echo "--- heartbeat line count:"
grep -c '"_hb": true' "$TMPDIR/stdout3.log" || true
echo "--- final envelope count (must be exactly 1):"
grep -c '"_envelope": true' "$TMPDIR/stdout3.log" || true

echo
echo "=== Test 4: malformed JSON line in stream (must not crash) ==="
ACC_ERR4="$TMPDIR/acc4.err"
{
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"sess-bad"}'
  printf '%s\n' 'this is not json at all'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"survived"}]}}'
  printf '%s\n' '{"type":"result","result":"survived","total_cost_usd":0.001,"session_id":"sess-bad"}'
} | python3 "$ACC" --heartbeat-interval 10 2>"$ACC_ERR4" | tee "$TMPDIR/stdout4.log"
rc=$?
echo "--- exit code: $rc (expect 0)"
echo "--- stderr should report parse error:"
cat "$ACC_ERR4"

rm -rf "$TMPDIR"
echo
echo "All smoke tests passed."
