#!/usr/bin/env bash
# tier-check.sh — F6b.2a dry-run wrapper for the complexity tier classifier.
#
# Runs the same classifier the orchestrator uses (scripts/lib/complexity_tier.py)
# against a task body — either a task id pulled from a TASK_QUEUE.md, or a
# plain file on disk. Prints a human-readable verdict: tier, which decision
# branch fired, and the raw signals. No journal writes, no side effects.
#
# Motivation (F6b.2a): the 1-kw + files>1 RISKY branch was not exercised in
# the NC-408..412 observation batch. Before that rule becomes behavior-
# affecting in F6b.2b (tier-specific caps), operators should be able to run
# sample tasks through the classifier in isolation and spot-check that each
# of the five branches fires where it should.
#
# USAGE:
#   tier-check.sh --id NC-413 [--queue /path/to/TASK_QUEUE.md]
#   tier-check.sh --file /path/to/task.md
#   cat task.md | tier-check.sh --stdin
#
# --queue defaults to $PROJECT_PATH/TASK_QUEUE.md (or $PWD/TASK_QUEUE.md if
# PROJECT_PATH is unset).
#
# Exit codes:
#   0 — classification succeeded (verdict printed)
#   1 — usage error
#   2 — classifier failed (e.g. Python missing, parse error)
#   3 — task id not found in queue
#
# Example:
#   $ scripts/tier-check.sh --id NC-412
#   task: NC-412
#   tier: RISKY
#   branch: ge_2_keywords
#   ac_count: 4
#   listed_files: 3
#   keywords: schema, migration
#   keywords_raw: schema, migration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLASSIFIER="$SCRIPT_DIR/lib/complexity_tier.py"

usage() {
    sed -n '3,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
}

mode=""
id=""
file=""
queue="${PROJECT_PATH:-$PWD}/TASK_QUEUE.md"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --id)     mode="id"; id="${2:?--id requires a task id}"; shift 2 ;;
        --file)   mode="file"; file="${2:?--file requires a path}"; shift 2 ;;
        --stdin)  mode="stdin"; shift ;;
        --queue)  queue="${2:?--queue requires a path}"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "tier-check: unknown arg: $1" >&2; usage ;;
    esac
done

[[ -z "$mode" ]] && usage

if [[ ! -f "$CLASSIFIER" ]]; then
    echo "tier-check: classifier not found: $CLASSIFIER" >&2
    exit 2
fi

# -----------------------------------------------------------------------------
# extract_task_body QUEUE_PATH TASK_ID -> body on stdout
#
# Matches the first markdown heading that contains "<TASK_ID>" (case-sensitive,
# whole-word-ish), then captures everything until the next heading at the
# same-or-shallower level or EOF. We accept either "#### NC-412 [ ] Title"
# or "### NC-412: Title" and similar — common patterns in Nightcrawler-
# managed queues — by requiring the id to follow a run of '#' + whitespace.
# -----------------------------------------------------------------------------
extract_task_body() {
    local queue_path="$1" task_id="$2"
    python3 - "$queue_path" "$task_id" <<'PY'
import re, sys
queue_path, task_id = sys.argv[1], sys.argv[2]
try:
    text = open(queue_path).read()
except OSError as e:
    print(f"tier-check: cannot read queue '{queue_path}': {e}", file=sys.stderr)
    sys.exit(3)

# Find the heading line for this task id.
esc = re.escape(task_id)
pat = re.compile(rf"^(#{{1,6}})\s+.*\b{esc}\b.*$", re.MULTILINE)
m = pat.search(text)
if not m:
    print(f"tier-check: task id '{task_id}' not found in {queue_path}", file=sys.stderr)
    sys.exit(3)

start = m.start()
level = len(m.group(1))
# End: next heading of same-or-shallower depth.
tail = text[m.end():]
end_pat = re.compile(rf"^#{{1,{level}}}\s", re.MULTILINE)
em = end_pat.search(tail)
end = m.end() + (em.start() if em else len(tail))
sys.stdout.write(text[start:end])
PY
}

# Build the body we classify.
body_file=$(mktemp)
trap 'rm -f "$body_file"' EXIT

case "$mode" in
    id)
        extract_task_body "$queue" "$id" > "$body_file" || exit $?
        ;;
    file)
        [[ -f "$file" ]] || { echo "tier-check: file not found: $file" >&2; exit 1; }
        cat "$file" > "$body_file"
        ;;
    stdin)
        cat > "$body_file"
        ;;
esac

# Run classifier.
out=$(python3 "$CLASSIFIER" < "$body_file") || {
    echo "tier-check: classifier failed (see above)" >&2
    exit 2
}

# Pretty-print. Keep JSON as the final line for easy grep/jq consumption.
python3 - "$out" "$mode" "$id" "$file" <<'PY'
import json, sys
raw, mode, task_id, task_file = sys.argv[1:5]
d = json.loads(raw)
tier = d.get("tier", "UNKNOWN")
sig  = d.get("signals", {})
label = task_id if mode == "id" else (task_file if mode == "file" else "<stdin>")
print(f"task: {label}")
print(f"tier: {tier}")
print(f"branch: {sig.get('branch', '?')}")
print(f"ac_count: {sig.get('ac_count', 0)}")
print(f"listed_files: {sig.get('listed_files', 0)}")
kws     = sig.get("keywords", []) or []
kws_raw = sig.get("keywords_raw", []) or []
print(f"keywords: {', '.join(kws) if kws else '(none)'}")
if kws_raw != kws:
    print(f"keywords_raw: {', '.join(kws_raw) if kws_raw else '(none)'}  # filters fired")
else:
    print(f"keywords_raw: {', '.join(kws_raw) if kws_raw else '(none)'}")
print(f"signals_json: {json.dumps(sig, separators=(',',':'))}")
PY
