#!/usr/bin/env python3
"""Auto-resume scanner for the Nightcrawler feat runner.

Scans the persisted feat-state directory and REPORTS which feats are safe to auto-resume — a feat
that was mid-flight (status == "running") when its run was interrupted (machine restart, watchdog
kill, scheduled-task timeout). It does NOT execute anything: it only emits the args a scheduler /
watchdog would feed back into the `nightcrawler-feat` workflow to pick the run back up.

  resume_scan.py [FEATS_DIR]     # default ~/.nightcrawler/feats ; prints a JSON array on stdout

WIRING TO A SCHEDULE (the scanner only REPORTS — the schedule does the re-invoke):
  1. On a timer (e.g. cron / a scheduled task every N minutes) run:  resume_scan.py
  2. For each object in the printed JSON array, re-invoke the feat workflow with its args:
         workflow('nightcrawler-feat', { feat: <feat>, tasks: <tasks> })
     (the feat runner is idempotent on resume: preflight reads the same state file, carries
      forward done/noop tasks, and re-cuts the feat branch — so re-invoking a running feat
      simply continues it). `base` is reported for context/logging; the runner re-derives it.
  3. NEVER auto-resume a feat NOT in this list — those reached a deliberate terminal state.

SAFE-to-auto-resume rule:  status == "running" ONLY.

Terminal / NOT auto-resumable (a deliberate stop — a human must decide what happens next):
  done, done_with_noops   — the feat finished; nothing left to run.
  halted                  — a task failed; M1 will not build later tasks on a failed one.
  needs_human             — paused for a human decision (resume needs an `answers` map, not a
                            blind re-invoke — so it is excluded here on purpose).
  dirty_tree              — base tree was dirty; resuming would need a human to clean it.
  base_red                — baseline verify failed; the base is broken.
  env_not_ready           — environment not runnable; needs a human/install fix first.
  infra_error             — an agent/runner failure; needs investigation.
  feat_integration_failed — the merged feat broke integration verify; needs a human.
"""
import json
import os
import sys

# The ONLY status that is safe to auto-resume: a run that was actively in-flight when interrupted.
RESUMABLE_STATUS = "running"

# Deliberate terminal states — documented here so the exclusion set is explicit and testable.
# Anything not == RESUMABLE_STATUS is excluded; this tuple is the human-readable enumeration.
TERMINAL_STATUSES = (
    "done",
    "done_with_noops",
    "halted",
    "needs_human",
    "dirty_tree",
    "base_red",
    "env_not_ready",
    "infra_error",
    "feat_integration_failed",
)


def _read_feat(path):
    """Return the parsed feat-state object, or None if the file is missing/empty/malformed."""
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
    except OSError:
        return None
    raw = raw.strip()
    if not raw:
        return None
    try:
        obj = json.loads(raw)
    except (ValueError, TypeError):
        return None
    if not isinstance(obj, dict):
        return None
    return obj


def _resumable_entry(obj):
    """Map a feat-state object to the resume args, or None if it is not safe to auto-resume.

    SAFE = status == "running" ONLY. Also requires the fields a resumer needs to reconstruct the
    original workflow args (featId, feat title, tasks list) — a state missing those can't be
    re-invoked, so it is skipped rather than emitted as a broken resume request."""
    if not isinstance(obj, dict):
        return None
    if obj.get("status") != RESUMABLE_STATUS:
        return None
    feat_id = obj.get("featId")
    feat = obj.get("feat")          # the title — persisted exactly so resume can rebuild the args
    tasks = obj.get("tasks")
    if not feat_id or not feat or not isinstance(tasks, list):
        return None
    # The feat runner takes args.tasks as a list of task SPEC strings (it re-derives ids/branches).
    specs = [t.get("spec") for t in tasks if isinstance(t, dict) and t.get("spec")]
    if not specs:
        return None
    return {
        "featId": feat_id,
        "feat": feat,
        "tasks": specs,
        "base": obj.get("base"),
    }


def scan(feats_dir):
    """Return the list of resume-arg objects for every SAFE-to-resume feat under feats_dir.

    Files that don't exist, are empty, are malformed JSON, or are in any terminal state are
    silently skipped — the scanner never raises on a bad file and never reports a terminal feat."""
    out = []
    try:
        names = sorted(os.listdir(feats_dir))
    except OSError:
        return out                  # no feats dir yet → nothing to resume
    for name in names:
        if not name.endswith(".json"):
            continue
        obj = _read_feat(os.path.join(feats_dir, name))
        if obj is None:
            continue
        entry = _resumable_entry(obj)
        if entry is not None:
            out.append(entry)
    return out


def default_feats_dir():
    return os.path.join(os.path.expanduser("~"), ".nightcrawler", "feats")


def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    feats_dir = argv[0] if argv else default_feats_dir()
    print(json.dumps(scan(feats_dir), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
