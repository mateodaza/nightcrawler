#!/bin/bash
# watchdog.sh — Independent watchdog for Nightcrawler (runs via cron)
# Checks heartbeat file staleness. Alerts via OpenClaw's Telegram if stale.
# This runs OUTSIDE OpenClaw — if OpenClaw is dead, this catches it.
#
# Cron: */30 * * * * /home/nightcrawler/nightcrawler/scripts/watchdog.sh

HEARTBEAT_FILE="/tmp/nightcrawler-heartbeat"
ALERTED_FILE="/tmp/nightcrawler-watchdog-alerted"
MAX_AGE_MINUTES=30

# If no heartbeat file, no active session — clean up and exit
if [ ! -f "$HEARTBEAT_FILE" ]; then
    rm -f "$ALERTED_FILE"
    exit 0
fi

# Read session ID from heartbeat
SESSION_ID=$(head -1 "$HEARTBEAT_FILE" 2>/dev/null || echo "unknown")
FILE_AGE=$(( ($(date +%s) - $(stat -c %Y "$HEARTBEAT_FILE" 2>/dev/null || echo $(date +%s))) / 60 ))

if [ "$FILE_AGE" -gt "$MAX_AGE_MINUTES" ]; then
    # Only alert once per stale session
    if [ -f "$ALERTED_FILE" ] && [ "$(cat "$ALERTED_FILE")" = "$SESSION_ID" ]; then
        exit 0  # already alerted for this session
    fi

    # Log the alert
    echo "$(date -u +%FT%TZ) WATCHDOG: Session $SESSION_ID unresponsive for ${FILE_AGE}m" >> /home/nightcrawler/nightcrawler/watchdog.log

    # Mark as alerted for this session
    echo "$SESSION_ID" > "$ALERTED_FILE"

    # Try to alert via OpenClaw's Telegram (if openclaw is responding)
    # This is best-effort — if OpenClaw is truly dead, Mateo needs to SSH in
    openclaw send "⚠️ WATCHDOG — Session $SESSION_ID unresponsive for ${FILE_AGE}m. SSH into server and check." 2>/dev/null || true
fi
