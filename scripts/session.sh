#!/usr/bin/env bash
# session.sh — Session management helpers for Nightcrawler
# Usage: session.sh <command> [args...]
#
# Commands:
#   recover <project>               — Check for crash recovery needs
#   heartbeat-start <session-id>    — Start heartbeat (runs in background)
#   heartbeat-stop                  — Stop heartbeat
#   journal <session-id> <json>     — Append to session journal with fsync
#
# NOTE: Locking is handled by nightcrawler.sh via flock (acquire/check-lock/release removed).

set -euo pipefail

STATE_DIR="${NIGHTCRAWLER_STATE_PATH:-/home/nightcrawler/nightcrawler}"
LOCK_DIR="/tmp"
HEARTBEAT_FILE="/tmp/nightcrawler-heartbeat"

cmd="${1:-help}"
shift || true

case "$cmd" in

  recover)
    PROJECT="${1:?project required}"
    SESSIONS_DIR="$STATE_DIR/sessions"

    if [ ! -d "$SESSIONS_DIR" ]; then
      echo "CLEAN: No sessions directory"
      exit 0
    fi

    # Find most recent session for this project
    LATEST_JOURNAL=""
    LATEST_SESSION=""
    for d in "$SESSIONS_DIR"/*-"$PROJECT"; do
      if [ -f "$d/journal.jsonl" ]; then
        LATEST_JOURNAL="$d/journal.jsonl"
        LATEST_SESSION=$(basename "$d")
      fi
    done

    if [ -z "$LATEST_JOURNAL" ]; then
      echo "CLEAN: No previous sessions for project $PROJECT"
      exit 0
    fi

    # Check if last session completed cleanly
    if grep -q '"event":"session_complete"' "$LATEST_JOURNAL" 2>/dev/null || \
       grep -q '"event": "session_complete"' "$LATEST_JOURNAL" 2>/dev/null; then
      echo "CLEAN: Last session $LATEST_SESSION completed normally"
      exit 0
    fi

    echo "RECOVERY_NEEDED: Session $LATEST_SESSION did not complete"

    # Check last event
    LAST_EVENT=$(tail -1 "$LATEST_JOURNAL" 2>/dev/null || echo "")
    echo "LAST_EVENT: $LAST_EVENT"

    # Check for in-progress tasks in task queue
    PROJECT_PATH=$(python3 -c "
import yaml
with open('$STATE_DIR/config/openclaw.yaml') as f:
    cfg = yaml.safe_load(f)
print(cfg['projects']['$PROJECT']['path'])
" 2>/dev/null || echo "")

    if [ -n "$PROJECT_PATH" ] && [ -f "$PROJECT_PATH/TASK_QUEUE.md" ]; then
      IN_PROGRESS=$(grep -c '\[~\]' "$PROJECT_PATH/TASK_QUEUE.md" 2>/dev/null || echo "0")
      if [ "$IN_PROGRESS" -gt 0 ]; then
        echo "STALE_TASKS: $IN_PROGRESS tasks still marked [~] In Progress"
      fi
    fi
    ;;

  heartbeat-start)
    SESSION_ID="${1:?session-id required}"
    echo "Starting heartbeat for $SESSION_ID"

    while true; do
      echo "$SESSION_ID" > "$HEARTBEAT_FILE"
      echo "$$" >> "$HEARTBEAT_FILE"
      sleep 600  # 10 minutes
    done &

    HEARTBEAT_PID=$!
    echo "$HEARTBEAT_PID" > /tmp/nightcrawler-heartbeat-pid
    echo "HEARTBEAT: PID $HEARTBEAT_PID"
    ;;

  heartbeat-stop)
    if [ -f /tmp/nightcrawler-heartbeat-pid ]; then
      kill "$(cat /tmp/nightcrawler-heartbeat-pid)" 2>/dev/null || true
      rm -f /tmp/nightcrawler-heartbeat-pid
    fi
    rm -f "$HEARTBEAT_FILE"
    echo "HEARTBEAT: Stopped"
    ;;

  journal)
    SESSION_ID="${1:?session-id required}"
    JSON_LINE="${2:?json required}"
    JOURNAL_FILE="$STATE_DIR/sessions/$SESSION_ID/journal.jsonl"

    mkdir -p "$(dirname "$JOURNAL_FILE")"
    echo "$JSON_LINE" >> "$JOURNAL_FILE"
    # fsync via python for durability
    python3 -c "
import os
fd = os.open('$JOURNAL_FILE', os.O_RDONLY)
os.fsync(fd)
os.close(fd)
" 2>/dev/null || true
    ;;

  help|*)
    echo "Usage: session.sh <acquire|release|check-lock|recover|heartbeat-start|heartbeat-stop|journal> [args...]"
    exit 1
    ;;
esac
