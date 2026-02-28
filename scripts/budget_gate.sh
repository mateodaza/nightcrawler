#!/usr/bin/env bash
# budget_gate.sh — Hard budget enforcement wrapper.
# Wraps any Nightcrawler script call. Refuses to proceed if budget is blown.
#
# Usage: budget_gate.sh <session_id> <command...>
# Example: budget_gate.sh 20260301-034500-clout python3 ~/nightcrawler/scripts/call_opus.py plan ...
#
# This is the ONLY way scripts should be called during a session.
# It checks session, daily, and monthly caps BEFORE executing.

set -euo pipefail

SESSION_ID="${1:?Usage: budget_gate.sh <session_id> <command...>}"
shift

BUDGET_SCRIPT="${HOME}/nightcrawler/scripts/budget.py"
LOCKFILE="/tmp/nightcrawler-budget-kill"

# Hard kill — if this file exists, NOTHING runs
if [[ -f "$LOCKFILE" ]]; then
    echo '{"error": "BUDGET_KILLED", "reason": "Hard budget kill switch active. Remove /tmp/nightcrawler-budget-kill to resume."}' >&2
    exit 99
fi

# Check if budget is initialized
BUDGET_FILE="${HOME}/nightcrawler/sessions/${SESSION_ID}/budget.json"
if [[ ! -f "$BUDGET_FILE" ]]; then
    echo '{"error": "NO_BUDGET", "reason": "No budget initialized for session '"$SESSION_ID"'"}' >&2
    exit 98
fi

# Run budget check
CHECK=$(python3 "$BUDGET_SCRIPT" check "$SESSION_ID" 2>/dev/null || echo '{"can_continue": false}')
CAN_CONTINUE=$(echo "$CHECK" | python3 -c "import sys,json; print(json.load(sys.stdin).get('can_continue', False))" 2>/dev/null || echo "False")

if [[ "$CAN_CONTINUE" != "True" ]]; then
    # Extract details
    SESSION_REMAINING=$(echo "$CHECK" | python3 -c "import sys,json; print(json.load(sys.stdin).get('effective_remaining', 0))" 2>/dev/null || echo "0")
    DAILY_REMAINING=$(echo "$CHECK" | python3 -c "import sys,json; print(json.load(sys.stdin).get('daily_remaining', 0))" 2>/dev/null || echo "0")
    MONTHLY_REMAINING=$(echo "$CHECK" | python3 -c "import sys,json; print(json.load(sys.stdin).get('monthly_remaining', 0))" 2>/dev/null || echo "0")

    echo '{"error": "BUDGET_EXCEEDED", "session_remaining": '"$SESSION_REMAINING"', "daily_remaining": '"$DAILY_REMAINING"', "monthly_remaining": '"$MONTHLY_REMAINING"'}' >&2

    # Create kill switch if monthly is blown
    if (( $(echo "$MONTHLY_REMAINING <= 0" | bc -l) )); then
        touch "$LOCKFILE"
        echo "MONTHLY CAP HIT — kill switch activated at /tmp/nightcrawler-budget-kill" >&2
    fi

    exit 97
fi

# Budget OK — execute the actual command
exec "$@"
