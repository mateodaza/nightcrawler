#!/usr/bin/env bash
# f6-read.sh — F6b.2a observation reader.
#
# Takes a session id (or picks the most recent session) and prints the six
# signals we need to decide whether to move to F6b.2b (tier-specific caps):
#
#   1. Session header       — id, start/end, duration
#   2. Event totals         — count by event name (journal.jsonl)
#   3. Tier distribution    — from task_tier events (tier, branch, signals)
#   4. tier_mismatch rate   — # mismatches / # plan_audited with complexity_tier
#                              (F6b.1 baseline on un-calibrated camello was ~60%)
#   5. stance_applied cov.  — per-task count (expect ≥1 for F6b.2a+ sessions:
#                              at minimum plan's stance event fires)
#   6. Plan iterations/tier — plan_audited count per task, bucketed by tier
#   7. RISKY enumeration    — every RISKY task with listed_files, keywords,
#                              plan section count, plan line count, and a
#                              "UI-polish-shape" heuristic flag
#   8. Planner compliance   — does each mini_plan.md echo the tier name or
#                              tier-specific stance phrases? (weak signal,
#                              but catches planners that silently ignore
#                              the stance block)
#
# USAGE:
#   f6-read.sh                         # pick latest session under $SESSIONS_ROOT
#   f6-read.sh 20260421-205218-camello # specific session id
#   f6-read.sh --root /path/sessions   # override sessions root
#   f6-read.sh --json                  # emit machine-readable JSON (no prose)
#
# SESSIONS_ROOT defaults to /home/nightcrawler/nightcrawler/sessions (VPS)
# or $NIGHTCRAWLER_SESSIONS_ROOT if set.
#
# Exit codes:
#   0 — ok
#   1 — usage error
#   2 — session not found / no sessions under root
#   3 — journal missing or unreadable

set -euo pipefail

SESSIONS_ROOT="${NIGHTCRAWLER_SESSIONS_ROOT:-/home/nightcrawler/nightcrawler/sessions}"
session_id=""
json_mode="false"

usage() {
    sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)  SESSIONS_ROOT="${2:?--root requires a path}"; shift 2 ;;
        --json)  json_mode="true"; shift ;;
        -h|--help) usage ;;
        --*)     echo "f6-read: unknown flag: $1" >&2; usage ;;
        *)       session_id="$1"; shift ;;
    esac
done

if [[ ! -d "$SESSIONS_ROOT" ]]; then
    echo "f6-read: sessions root not found: $SESSIONS_ROOT" >&2
    exit 2
fi

# Auto-pick latest session if none specified. We glob directories that look
# like a session id (YYYYMMDD-HHMMSS-*), not arbitrary entries (e.g. a stray
# SESSION_ID=... file that can appear from a mis-exported env).
if [[ -z "$session_id" ]]; then
    session_id=$(ls -1d "$SESSIONS_ROOT"/[0-9]*/ 2>/dev/null \
        | sed 's|/$||' | xargs -n1 basename 2>/dev/null \
        | sort | tail -1)
    if [[ -z "$session_id" ]]; then
        echo "f6-read: no sessions found under $SESSIONS_ROOT" >&2
        exit 2
    fi
fi

SESSION_DIR="$SESSIONS_ROOT/$session_id"
JOURNAL="$SESSION_DIR/journal.jsonl"
TASKS_DIR="$SESSION_DIR/tasks"

if [[ ! -d "$SESSION_DIR" ]]; then
    echo "f6-read: session dir not found: $SESSION_DIR" >&2
    exit 2
fi
if [[ ! -f "$JOURNAL" ]]; then
    echo "f6-read: journal not found: $JOURNAL" >&2
    exit 3
fi

# -----------------------------------------------------------------------------
# Heavy lifting in Python — parse journal, cross-reference task dirs, grep
# mini_plan.md for compliance phrases, print the report.
# -----------------------------------------------------------------------------
python3 - "$SESSION_DIR" "$JOURNAL" "$TASKS_DIR" "$json_mode" <<'PY'
import json, sys, os, re
from collections import Counter, defaultdict

session_dir, journal, tasks_dir, json_mode = sys.argv[1:5]
json_mode = (json_mode == "true")

# ----- load events -----
events = []
with open(journal) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try: events.append(json.loads(line))
        except json.JSONDecodeError: pass

# ----- session header -----
session_start = next((e for e in events if e.get("event") == "session_start"), {})
session_complete = next((e for e in events if e.get("event") == "session_complete"), {})
session_id = os.path.basename(session_dir.rstrip("/"))

# ----- event totals -----
event_counts = Counter(e.get("event", "?") for e in events)

# ----- tier distribution -----
task_tiers = {}  # task_id -> {"tier":..., "signals":{...}}
for e in events:
    if e.get("event") == "task_tier":
        tid = e.get("task_id")
        if tid:
            task_tiers[tid] = {"tier": e.get("tier","UNKNOWN"), "signals": e.get("signals",{})}

tier_dist = Counter(v["tier"] for v in task_tiers.values())
branch_dist = Counter(v["signals"].get("branch","?") for v in task_tiers.values())

# ----- tier_mismatch rate -----
plan_audited = [e for e in events if e.get("event") == "plan_audited"]
plan_audits_with_tier = [e for e in plan_audited if e.get("complexity_tier")]
tier_mismatches = [e for e in events if e.get("event") == "tier_mismatch"]
mismatch_rate = (len(tier_mismatches) / len(plan_audits_with_tier)) if plan_audits_with_tier else 0.0

# ----- stance_applied coverage -----
stance_per_task = defaultdict(list)  # task_id -> [event, ...]
for e in events:
    if e.get("event") == "stance_applied":
        tid = e.get("task_id")
        if tid:
            stance_per_task[tid].append(e)

stance_covered = sum(1 for tid in task_tiers if tid in stance_per_task and stance_per_task[tid])
stance_total = len(task_tiers)
stance_coverage = (stance_covered / stance_total) if stance_total else 0.0

# ----- plan iterations by tier -----
plan_audits_per_task = Counter(e.get("task_id") for e in plan_audited if e.get("task_id"))
iter_by_tier = defaultdict(list)  # tier -> [iter_count, ...]
for tid, info in task_tiers.items():
    iter_by_tier[info["tier"]].append(plan_audits_per_task.get(tid, 0))

# ----- plan inflation (B4.1) -----
plan_inflations = [e for e in events if e.get("event") == "plan_inflation_detected"]
inflation_by_task = defaultdict(list)  # task_id -> [event, ...]
for e in plan_inflations:
    tid = e.get("task_id")
    if tid:
        inflation_by_task[tid].append(e)

# ----- RISKY enumeration + mini_plan inspection -----
# Keywords that suggest a UI-polish shape (for the RISKY false-strictness
# check — if a RISKY task is overwhelmingly UI-polish, the stance may be
# causing unnecessary scaffolding).
UI_POLISH_HINTS = {"animate","transition","hover","tooltip","modal","layout",
                   "spinner","skeleton","style","css","theme","padding","margin",
                   "copy","label","badge","icon"}
# Stance phrases we can grep each mini_plan.md for. The planner is not
# required to echo these verbatim; presence is a positive compliance signal,
# absence alone doesn't mean the planner ignored the stance.
STANCE_PHRASES = {
    "TRIVIAL":  ["one-line edit","minimal test","do not invent scaffolding","scope"],
    "STANDARD": ["happy path","edge case","conventions"],
    "RISKY":    ["enumerate","every surface","tenant scoping","authorization",
                 "migration","schema","per surface","exhaustive"],
}

def read_plan(tid):
    path = os.path.join(tasks_dir, tid, "mini_plan.md")
    if not os.path.isfile(path): return None
    try:
        return open(path, errors="replace").read()
    except OSError:
        return None

risky_rows = []
compliance_rows = []
for tid, info in sorted(task_tiers.items()):
    tier = info["tier"]
    sig = info["signals"]
    plan = read_plan(tid)
    plan_lines = plan.count("\n") if plan else 0
    plan_sections = len(re.findall(r"^#{2,4}\s", plan, re.MULTILINE)) if plan else 0

    # Planner compliance: tier name mention + matching stance phrases found.
    tier_name_mentioned = bool(plan and re.search(rf"\b{re.escape(tier)}\b", plan))
    phrase_hits = []
    if plan:
        low = plan.lower()
        for p in STANCE_PHRASES.get(tier, []):
            if p.lower() in low:
                phrase_hits.append(p)
    compliance_rows.append({
        "task_id": tid, "tier": tier,
        "plan_lines": plan_lines, "plan_sections": plan_sections,
        "tier_name_mentioned": tier_name_mentioned,
        "phrase_hits": phrase_hits,
        "plan_exists": plan is not None,
    })

    if tier == "RISKY":
        kws_raw = sig.get("keywords_raw", []) or []
        ui_hint_count = sum(1 for k in kws_raw if k.lower() in UI_POLISH_HINTS)
        # UI-polish-shape heuristic: no auth/schema/migration keywords,
        # and plan has few sections, and at least one UI hint in the raw
        # keyword set. This is deliberately conservative — we're flagging
        # for manual review, not auto-demoting.
        hard_kws = {"auth","migration","schema","tenant","permission","role"}
        has_hard_kw = any(k.lower() in hard_kws for k in kws_raw)
        possibly_ui_polish = (not has_hard_kw) and (ui_hint_count > 0 or plan_sections <= 3)
        risky_rows.append({
            "task_id": tid, "branch": sig.get("branch","?"),
            "ac_count": sig.get("ac_count",0), "listed_files": sig.get("listed_files",0),
            "keywords": sig.get("keywords",[]), "keywords_raw": kws_raw,
            "plan_lines": plan_lines, "plan_sections": plan_sections,
            "possibly_ui_polish": possibly_ui_polish,
        })

# ----- output -----
if json_mode:
    out = {
        "session_id": session_id,
        "session_dir": session_dir,
        "event_counts": dict(event_counts),
        "task_tiers": task_tiers,
        "tier_distribution": dict(tier_dist),
        "branch_distribution": dict(branch_dist),
        "tier_mismatch": {
            "mismatches": len(tier_mismatches),
            "plan_audits_with_tier": len(plan_audits_with_tier),
            "rate": round(mismatch_rate, 3),
            "baseline_f6b1_pct": 0.60,
        },
        "stance_applied": {
            "covered_tasks": stance_covered,
            "total_tasks": stance_total,
            "coverage": round(stance_coverage, 3),
            "per_task": {tid: len(evs) for tid, evs in stance_per_task.items()},
        },
        "plan_iterations_by_tier": {t: iters for t, iters in iter_by_tier.items()},
        "risky_tasks": risky_rows,
        "compliance": compliance_rows,
    }
    print(json.dumps(out, indent=2, default=str))
    sys.exit(0)

# Prose report.
def hdr(t): print(f"\n=== {t} ===")

print(f"F6b.2a observation reader — session {session_id}")
print(f"Session dir: {session_dir}")
if session_start: print(f"Start: {session_start.get('timestamp','?')}")
if session_complete:
    print(f"End:   {session_complete.get('timestamp','?')}")

hdr("1. Event totals")
for ev, n in sorted(event_counts.items(), key=lambda x: -x[1]):
    print(f"  {n:4d}  {ev}")

hdr("2. Tier distribution")
total_tasks = sum(tier_dist.values()) or 1
for tier, n in tier_dist.most_common():
    pct = 100 * n / total_tasks
    print(f"  {tier:8s} {n:3d}  ({pct:5.1f}%)")
print("  branches:")
for br, n in branch_dist.most_common():
    print(f"    {br:24s} {n:3d}")

hdr("3. tier_mismatch rate")
print(f"  mismatches / plan_audits_with_tier = "
      f"{len(tier_mismatches)} / {len(plan_audits_with_tier)} = "
      f"{mismatch_rate*100:.1f}%  (F6b.1 baseline ~60%)")

hdr("4. stance_applied coverage")
if stance_total == 0:
    print("  (no tasks with task_tier events — cannot compute)")
else:
    print(f"  {stance_covered}/{stance_total} tasks have >=1 stance_applied event "
          f"({stance_coverage*100:.0f}%)")
    if stance_coverage < 1.0:
        missing = [tid for tid in sorted(task_tiers) if tid not in stance_per_task]
        print(f"  missing: {', '.join(missing)}")
        print("  NOTE: coverage <100% means either pre-F6b.2a session, or"
              " TIER_STANCE_FILE was not set for some tasks")
    # show per-task event counts for shape sanity
    print("  per-task event counts (should be >=1 plan + >=1 audit + >=1 review):")
    for tid in sorted(task_tiers):
        evs = stance_per_task.get(tid, [])
        phases = Counter(e.get("phase","?") for e in evs)
        phase_str = ", ".join(f"{p}={c}" for p,c in phases.items()) or "(none)"
        print(f"    {tid:10s} n={len(evs):2d}  {phase_str}")

hdr("5. Plan iterations by tier")
for tier in ["TRIVIAL","STANDARD","RISKY","UNKNOWN"]:
    iters = iter_by_tier.get(tier, [])
    if not iters: continue
    avg = sum(iters)/len(iters)
    print(f"  {tier:8s}  n={len(iters):2d}  avg={avg:.1f}  max={max(iters)}  iters={iters}")

hdr("6. RISKY enumeration")
if not risky_rows:
    print("  (no RISKY tasks — nothing to enumerate)")
else:
    for r in risky_rows:
        flag = "  [UI-POLISH-SHAPE?]" if r["possibly_ui_polish"] else ""
        print(f"  {r['task_id']}  branch={r['branch']}  ac={r['ac_count']}  "
              f"files={r['listed_files']}  kws_raw={r['keywords_raw']}  "
              f"plan={r['plan_lines']}L/{r['plan_sections']}§{flag}")
    n_flagged = sum(1 for r in risky_rows if r["possibly_ui_polish"])
    if n_flagged:
        print(f"  -> {n_flagged} RISKY task(s) flagged as possibly UI-polish shape;"
              " review manually for stance-induced scaffolding bloat.")

hdr("7. Planner compliance probe")
print("  Per-task: does mini_plan.md echo the tier name or stance phrases?")
print("  (presence = positive signal; absence is not proof of non-compliance)")
for row in compliance_rows:
    if not row["plan_exists"]:
        print(f"  {row['task_id']:10s} tier={row['tier']:8s} (no mini_plan.md)")
        continue
    tag = "YES" if row["tier_name_mentioned"] else "no "
    phrases = ", ".join(row["phrase_hits"]) or "(none)"
    print(f"  {row['task_id']:10s} tier={row['tier']:8s}  tier_in_plan={tag}  "
          f"plan={row['plan_lines']}L/{row['plan_sections']}§  phrases: {phrases}")

hdr("8. Plan inflation (B4.1)")
if not plan_inflations:
    print("  (no plan_inflation_detected events — clean batch)")
else:
    print(f"  {len(plan_inflations)} fire(s) across {len(inflation_by_task)} task(s).")
    for tid in sorted(inflation_by_task):
        rows = sorted(inflation_by_task[tid], key=lambda e: e.get("iteration", 0))
        print(f"  {tid}: {len(rows)} fire(s)")
        for e in rows:
            print(f"    iter={e.get('iteration')}  reason={e.get('reason')}  "
                  f"size={e.get('current_size_bytes')}B  "
                  f"from_initial=+{e.get('growth_from_initial_pct')}%  "
                  f"from_prior=+{e.get('growth_from_prior_pct')}%  "
                  f"repeat={e.get('repeated_blocker')}")

# Summary verdict hints — mechanical, not interpretive.
hdr("Summary")
verdict_notes = []
if stance_total and stance_coverage < 1.0:
    verdict_notes.append(
        f"stance_applied coverage is {stance_coverage*100:.0f}% (<100%) — "
        "expected 100% for post-F6b.2a sessions; investigate missing tasks")
if plan_audits_with_tier and mismatch_rate > 0.6:
    verdict_notes.append(
        f"tier_mismatch rate {mismatch_rate*100:.0f}% exceeds F6b.1 baseline (~60%) — "
        "classifier may be mis-calibrated relative to LLM judgment")
risky_flagged = [r for r in risky_rows if r["possibly_ui_polish"]]
if risky_flagged:
    verdict_notes.append(
        f"{len(risky_flagged)} RISKY task(s) have UI-polish shape — "
        "candidates for F6b.2b's stance-softening review")
if plan_inflations:
    verdict_notes.append(
        f"{len(plan_inflations)} plan_inflation_detected fire(s) across "
        f"{len(inflation_by_task)} task(s) — review per-task history (B4.2 candidates)")
if not verdict_notes:
    verdict_notes.append("no flags raised — observation looks clean")
for note in verdict_notes:
    print(f"  - {note}")
PY
