#!/usr/bin/env bash
# _resolve-path.sh — Resolve project path from openclaw.yaml registry
# Sourced by start.sh, nightcrawler.sh, diagnose.sh
#
# Resolution order:
#   1. NIGHTCRAWLER_PROJECT_PATH env var (manual override)
#   2. openclaw.yaml projects.<name>.path (set by nightcrawler-init)
#   3. /home/nightcrawler/projects/<name> (VPS default fallback)

_resolve_project_path() {
    local proj="$1"
    local scripts_dir="${SCRIPTS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

    # 1. Env override
    if [[ -n "${NIGHTCRAWLER_PROJECT_PATH:-}" ]]; then
        echo "$NIGHTCRAWLER_PROJECT_PATH"
        return
    fi

    # 2. Read from openclaw.yaml (nightcrawler-init stores the real path here)
    local yaml="$scripts_dir/../config/openclaw.yaml"
    if [[ -f "$yaml" ]] && command -v python3 &>/dev/null; then
        local p
        p=$(python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f) or {}
print(data.get('projects',{}).get(sys.argv[2],{}).get('path',''))
" "$yaml" "$proj" 2>/dev/null) || true
        if [[ -n "$p" ]]; then
            echo "$p"
            return
        fi
    fi

    # 3. Default fallback (VPS layout)
    echo "/home/nightcrawler/projects/$proj"
}
