#!/usr/bin/env bash
# Live VPS test for stream-accumulator.py.
#
# Run this on Mateo's Mac (from the nightcrawler clone). It:
#   1. scp's the accumulator to the VPS at /root/nightcrawler/scripts/lib/
#   2. runs `claude -p --output-format stream-json` piped into it
#   3. verifies the envelope, envelope-out file, and heartbeats
#   4. simulates a SIGTERM mid-stream to exercise the partial path
#
# Assumes the VPS alias from ~/.ssh/config is "nightcrawler" (or pass
# VPS=<alias> as env). Adjust ACC_PATH if /root/nightcrawler differs.
set -uo pipefail

VPS="${VPS:-nightcrawler}"
ACC_SRC="scripts/lib/stream-accumulator.py"
ACC_DST_DIR="/root/nightcrawler/scripts/lib"
ACC_DST="$ACC_DST_DIR/stream-accumulator.py"
OUT_DIR="scripts/lib/vps-test-out"
mkdir -p "$OUT_DIR"

echo "=== Step 1: ensure remote lib/ exists and scp the accumulator ==="
ssh "$VPS" "mkdir -p $ACC_DST_DIR"
scp "$ACC_SRC" "$VPS:$ACC_DST"
ssh "$VPS" "chmod +x $ACC_DST && python3 -c 'import ast; ast.parse(open(\"$ACC_DST\").read()); print(\"syntax ok\")'"

echo
echo "=== Step 2: natural-exit live test (short prompt) ==="
ssh "$VPS" "cd /tmp && rm -f nc_env.json nc_stdout.log nc_acc_err.log && \
  claude -p --output-format stream-json --verbose 'Reply with the single word: ACK' \
    2>/tmp/nc_cli_err.log \
  | python3 $ACC_DST --envelope-out /tmp/nc_env.json --heartbeat-interval 2 \
    2>/tmp/nc_acc_err.log \
  > /tmp/nc_stdout.log; \
  echo \"---pipe exit: \$?---\"; \
  echo '--- stdout (heartbeats + envelope):'; cat /tmp/nc_stdout.log; \
  echo '--- envelope-out file:'; cat /tmp/nc_env.json | python3 -m json.tool; \
  echo '--- accumulator stderr:'; cat /tmp/nc_acc_err.log; \
  echo '--- cli stderr (first 20 lines):'; head -20 /tmp/nc_cli_err.log" \
  | tee "$OUT_DIR/natural.log"

echo
echo "=== Step 3: partial-exit test (SIGTERM mid-turn) ==="
# Launch claude in the pipe, then kill the claude process (not the acc)
# after 2s. Accumulator should see stdin close and emit the partial envelope.
ssh "$VPS" "cd /tmp && rm -f nc_partial_env.json nc_partial_stdout.log nc_partial_acc_err.log && \
  (claude -p --output-format stream-json --verbose 'Count slowly from 1 to 50, one number per line.' 2>/tmp/nc_partial_cli_err.log & \
   cli_pid=\$!; \
   (sleep 2; kill -TERM \$cli_pid 2>/dev/null) & \
   wait \$cli_pid) \
  | python3 $ACC_DST --envelope-out /tmp/nc_partial_env.json --heartbeat-interval 1 \
    2>/tmp/nc_partial_acc_err.log \
  > /tmp/nc_partial_stdout.log; \
  echo \"---pipe exit: \$?---\"; \
  echo '--- partial stdout:'; cat /tmp/nc_partial_stdout.log; \
  echo '--- partial envelope-out file:'; cat /tmp/nc_partial_env.json | python3 -m json.tool; \
  echo '--- partial acc stderr:'; cat /tmp/nc_partial_acc_err.log" \
  | tee "$OUT_DIR/partial.log"

echo
echo "Done. Logs saved under $OUT_DIR/"
echo "  - $OUT_DIR/natural.log"
echo "  - $OUT_DIR/partial.log"
