#!/usr/bin/env bash
# nightcrawler-remove.sh — Deregister a project from Nightcrawler.
# Removes from openclaw.yaml and regenerates workspace. Does NOT delete project files.
#
# Usage: nightcrawler-remove.sh <project-name>

set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
NC_ROOT="$(dirname "$SCRIPTS")"
YAML="$NC_ROOT/config/openclaw.yaml"

PROJECT_NAME="${1:?Usage: nightcrawler-remove.sh <project-name>}"

# Pre-flight
if ! python3 -c "import yaml" 2>/dev/null; then
    echo "ERROR: PyYAML is required. Install with: pip install pyyaml"
    exit 1
fi

if [[ ! -f "$YAML" ]]; then
    echo "ERROR: openclaw.yaml not found at $YAML"
    exit 1
fi

# Check project exists in YAML
EXISTS=$(python3 -c "
import yaml
with open('$YAML') as f:
    data = yaml.safe_load(f) or {}
projects = data.get('projects', {}) or {}
print('yes' if '$PROJECT_NAME' in projects else 'no')
")

if [[ "$EXISTS" != "yes" ]]; then
    echo "ERROR: Project '$PROJECT_NAME' not found in openclaw.yaml"
    exit 1
fi

# Check for active session (refuse removal if lock is held)
LOCK_FILE="/tmp/nightcrawler-${PROJECT_NAME}.lock"
if [[ -f "$LOCK_FILE" ]] && ! flock -n "$LOCK_FILE" true 2>/dev/null; then
    echo "ERROR: Cannot remove '$PROJECT_NAME' — session is active (lock held at $LOCK_FILE)"
    echo "Run 'stop' first, then retry."
    exit 1
fi

# Confirm
echo "Remove project '$PROJECT_NAME'?"
echo "  - Delete from openclaw.yaml"
echo "  - Regenerate workspace/NIGHTCRAWLER.md"
echo "  - .nightcrawler/ in project dir will NOT be deleted"
printf "Confirm (y/n): "
read -r CONFIRM

if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

# Remove from YAML
NC_PROJ_NAME="$PROJECT_NAME" python3 - "$YAML" << 'PYEOF'
import yaml, sys, os

yaml_path = sys.argv[1]
name = os.environ['NC_PROJ_NAME']

with open(yaml_path, 'r') as f:
    data = yaml.safe_load(f) or {}

projects = data.get('projects', {}) or {}
projects.pop(name, None)
data['projects'] = projects

with open(yaml_path, 'w') as f:
    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
PYEOF

echo "Removed '$PROJECT_NAME' from openclaw.yaml"

# Regenerate workspace
if [[ -x "$SCRIPTS/generate-workspace.sh" ]]; then
    bash "$SCRIPTS/generate-workspace.sh"
    echo "Regenerated workspace/NIGHTCRAWLER.md"
fi

echo "Done."
