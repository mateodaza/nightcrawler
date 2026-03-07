#!/usr/bin/env bash
# nightcrawler-list.sh — List all registered projects and their status.
#
# Usage: nightcrawler-list.sh

set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
NC_ROOT="$(dirname "$SCRIPTS")"
YAML="$NC_ROOT/config/openclaw.yaml"

if ! python3 -c "import yaml" 2>/dev/null; then
    echo "ERROR: PyYAML is required. Install with: pip install pyyaml"
    exit 1
fi

if [[ ! -f "$YAML" ]]; then
    echo "No openclaw.yaml found. Run 'nightcrawler init' to register a project."
    exit 0
fi

# Parse projects from YAML
PROJECTS_JSON=$(python3 -c "
import yaml, json
with open('$YAML') as f:
    data = yaml.safe_load(f) or {}
projects = data.get('projects', {}) or {}
json.dump(projects, __import__('sys').stdout)
")

if [[ "$PROJECTS_JSON" == "{}" ]]; then
    echo "No projects registered. Run 'nightcrawler init' to add one."
    exit 0
fi

# Header
printf "%-15s %-45s %-12s %s\n" "PROJECT" "PATH" "STATUS" "LAST SESSION"
printf "%-15s %-45s %-12s %s\n" "-------" "----" "------" "------------"

# Iterate projects
python3 -c "
import json, sys
projects = json.loads('''$PROJECTS_JSON''')
for name in projects:
    print(name)
" | while read -r name; do
    path=$(python3 -c "import json; print(json.loads('''$PROJECTS_JSON''')['$name'].get('path', '?'))")

    # Status check
    status="OK"
    if [[ ! -d "$path" ]]; then
        status="NO PATH"
    elif [[ ! -f "$path/.nightcrawler/config.sh" ]]; then
        status="NO CONFIG"
    fi

    # Check for active session
    lockfile="/tmp/nightcrawler-${name}.lock"
    if [[ -f "$lockfile" ]] && ! flock -n "$lockfile" true 2>/dev/null; then
        status="RUNNING"
    fi

    # Last session
    last_session="never"
    sessions_dir="/home/nightcrawler/nightcrawler/sessions"
    if [[ -d "$sessions_dir" ]]; then
        latest=$(ls -d "$sessions_dir"/*-"$name" 2>/dev/null | sort | tail -1)
        if [[ -n "$latest" ]]; then
            last_session=$(basename "$latest" | sed "s/-${name}$//")
        fi
    fi

    printf "%-15s %-45s %-12s %s\n" "$name" "$path" "$status" "$last_session"
done
