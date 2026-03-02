#!/usr/bin/env bash
# queue-tasks.sh — Show eligible tasks from BACKLOG.md and optionally add them to TASK_QUEUE.md
#
# Usage:
#   queue-tasks.sh <project_path>              Show eligible tasks (deps met, not already queued)
#   queue-tasks.sh <project_path> --add NC-004 NC-005   Add specific tasks to queue
#
set -euo pipefail

PROJECT_PATH="${1:?Usage: queue-tasks.sh <project_path> [--add NC-XXX ...]}"
shift

BACKLOG="$PROJECT_PATH/BACKLOG.md"
QUEUE="$PROJECT_PATH/TASK_QUEUE.md"

if [[ ! -f "$BACKLOG" ]]; then
    echo "No BACKLOG.md found in $PROJECT_PATH"
    exit 1
fi

if [[ ! -f "$QUEUE" ]]; then
    echo "No TASK_QUEUE.md found in $PROJECT_PATH"
    exit 1
fi

# Mode: --add or show
if [[ "${1:-}" == "--add" ]]; then
    shift
    TASK_IDS=("$@")
    if [[ ${#TASK_IDS[@]} -eq 0 ]]; then
        echo "No task IDs provided. Usage: queue-tasks.sh <project_path> --add NC-004 NC-005"
        exit 1
    fi

    added=0
    for tid in "${TASK_IDS[@]}"; do
        # Check not already in queue
        if grep -qE "^#{1,6}\s+${tid}\s+\[" "$QUEUE"; then
            echo "SKIP: $tid already in queue"
            continue
        fi

        # Extract full task block from BACKLOG.md
        block=$(python3 -c "
import re, sys

tid = '$tid'
with open('$BACKLOG') as f:
    lines = f.readlines()

header_re = re.compile(r'^(#{1,6})\s+(NC-\d+)\s+')
capturing = False
block = []

for line in lines:
    m = header_re.match(line)
    if m:
        if capturing:
            break
        if m.group(2) == tid:
            capturing = True
            # Force status to [ ] (queued)
            block.append(header_re.sub(lambda x: x.group(1) + ' ' + tid + ' [ ] ', line))
            continue
    if capturing:
        block.append(line)

if block:
    # Strip trailing blank lines
    while block and not block[-1].strip():
        block.pop()
    print(''.join(block))
else:
    print('')
" 2>/dev/null)

        if [[ -z "$block" ]]; then
            echo "SKIP: $tid not found in BACKLOG.md"
            continue
        fi

        # Append to queue
        printf "\n%s\n" "$block" >> "$QUEUE"
        echo "ADDED: $tid"
        added=$((added + 1))
    done

    echo "---"
    echo "$added task(s) added to queue."
else
    # Show eligible tasks
    python3 -c "
import re

with open('$QUEUE') as f:
    queue_content = f.read()
with open('$BACKLOG') as f:
    backlog_content = f.read()

header_re = re.compile(r'^(#{1,6})\s+(NC-\d+)\s+\[(.)\](.*)$')

# Find all task IDs already in queue (any status)
queued_ids = set()
done_ids = set()
for line in queue_content.splitlines():
    m = header_re.match(line)
    if m:
        queued_ids.add(m.group(2))
        if m.group(3) == 'x':
            done_ids.add(m.group(2))

# Parse backlog for tasks not yet queued
dep_re = re.compile(r'^\-\s+\*\*Dependencies?:\*\*\s*(.*)', re.IGNORECASE)
backlog_lines = backlog_content.splitlines()

tasks = []  # (id, title, deps, eligible)
current = None
for line in backlog_lines:
    m = header_re.match(line)
    if m:
        if current and current['id'] not in queued_ids:
            # Previous task had no deps line — eligible
            current['eligible'] = True
            tasks.append(current)
        tid = m.group(2)
        title = m.group(4).strip()
        if tid in queued_ids:
            current = None
            continue
        current = {'id': tid, 'title': title, 'deps': [], 'eligible': True}
        continue

    if current:
        dm = dep_re.match(line.strip())
        if dm:
            dep_str = dm.group(1).strip()
            if dep_str.lower() != 'none' and dep_str:
                deps = [d.strip() for d in dep_str.split(',') if d.strip()]
                current['deps'] = deps
                current['eligible'] = all(d in done_ids for d in deps)
            tasks.append(current)
            current = None

# Last task
if current and current['id'] not in queued_ids:
    tasks.append(current)

eligible = [t for t in tasks if t['eligible']]
blocked = [t for t in tasks if not t['eligible']]

if not eligible and not blocked:
    print('All backlog tasks are already queued.')
else:
    if eligible:
        print('READY (deps met):')
        for t in eligible:
            deps = ', '.join(t['deps']) if t['deps'] else 'None'
            print(f\"  {t['id']} — {t['title']} (deps: {deps})\")
    if blocked:
        print()
        print('BLOCKED (deps not done):')
        for t in blocked:
            missing = [d for d in t['deps'] if d not in done_ids]
            print(f\"  {t['id']} — {t['title']} (waiting on: {', '.join(missing)})\")

    if eligible:
        print()
        print('To add: queue add ' + ' '.join(t['id'] for t in eligible))
"
fi
