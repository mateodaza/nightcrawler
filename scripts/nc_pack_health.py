#!/usr/bin/env python3
"""Nightcrawler pack health monitor — one-screen canary for F1 relevance packs.

Walks the last N Nightcrawler sessions under ~/.nightcrawler/sessions and
flags anomalies that would make a default-on run untrustworthy:

  * missing sidecar pair (.txt or .meta.json absent for audit/review)
  * zero-entry pack (entries=[] in meta.json)
  * tiny pack      (txt size below --min-bytes, default 1500)
  * oversized pack (txt size above --max-bytes, default 30000)
  * degraded mode  (WARN line in nightcrawler.log)

Prints one line per task per session. Exit code is 1 if anything is flagged,
0 otherwise — so this can be tailed by cron or a manual "how did last night
look?" check.

Default scope: last 10 sessions. Override with --limit.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SESSIONS_ROOT = Path.home() / ".nightcrawler" / "sessions"
PHASES = ("plan_audit", "impl_review")


def inspect_pack(pack_dir: Path, task_id: str, phase: str,
                 min_bytes: int, max_bytes: int) -> tuple[str, list[str]]:
    """Return ("<size>/<entries>", [flag, ...]) for one (task, phase) pair."""
    txt = pack_dir / f"{task_id}.{phase}.txt"
    meta = pack_dir / f"{task_id}.{phase}.meta.json"
    flags: list[str] = []

    if not txt.exists() and not meta.exists():
        return "--/--", [f"{phase}:missing"]
    if not txt.exists():
        flags.append(f"{phase}:txt-missing")
    if not meta.exists():
        flags.append(f"{phase}:meta-missing")

    size = txt.stat().st_size if txt.exists() else 0
    entries = 0
    if meta.exists():
        try:
            entries = len(json.loads(meta.read_text()).get("entries", []))
        except (json.JSONDecodeError, OSError) as exc:
            flags.append(f"{phase}:meta-unreadable({type(exc).__name__})")

    if txt.exists():
        if entries == 0:
            flags.append(f"{phase}:zero-entries")
        if size < min_bytes:
            flags.append(f"{phase}:tiny({size}B)")
        if size > max_bytes:
            flags.append(f"{phase}:oversized({size}B)")

    return f"{size/1024:.1f}K/{entries}e", flags


def scan_session(session_dir: Path, min_bytes: int, max_bytes: int) -> list[dict] | None:
    """Return per-task rows, or None if the session is pre-F1 (no packs dir)."""
    packs = session_dir / "relevance-packs"
    # Pre-F1 sessions (or runs with NC_RELEVANCE_PACK=0) have no packs dir at
    # all. That is not an anomaly — it's just a run that didn't use F1.
    if not packs.is_dir():
        return None

    rows: list[dict] = []

    # Collect task IDs from sidecar filenames (works even mid-run).
    task_ids: set[str] = set()
    for f in packs.iterdir():
        name = f.name
        for phase in PHASES:
            suffix = f".{phase}.txt"
            if name.endswith(suffix):
                task_ids.add(name[: -len(suffix)])
                continue
            suffix = f".{phase}.meta.json"
            if name.endswith(suffix):
                task_ids.add(name[: -len(suffix)])

    # Degraded-mode check: one grep over nightcrawler.log per session.
    degraded = False
    log = session_dir / "nightcrawler.log"
    if log.exists():
        try:
            blob = log.read_text(errors="replace")
            degraded = ("entering degraded mode" in blob
                        or "DEGRADED MODE" in blob)
        except OSError:
            pass

    if not task_ids:
        rows.append({
            "task": "(empty packs/)",
            "plan": "--/--",
            "review": "--/--",
            "flags": (["degraded", "empty-dir"] if degraded else ["empty-dir"]),
        })
        return rows

    for task_id in sorted(task_ids):
        plan_s, plan_f = inspect_pack(packs, task_id, "plan_audit",
                                      min_bytes, max_bytes)
        rev_s, rev_f = inspect_pack(packs, task_id, "impl_review",
                                    min_bytes, max_bytes)
        flags = plan_f + rev_f
        if degraded:
            flags.append("degraded")
        rows.append({
            "task": task_id,
            "plan": plan_s,
            "review": rev_s,
            "flags": flags,
        })
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--limit", type=int, default=10,
                    help="max sessions to scan (default: 10)")
    ap.add_argument("--min-bytes", type=int, default=1500,
                    help="flag if pack txt < this (default: 1500)")
    ap.add_argument("--max-bytes", type=int, default=30000,
                    help="flag if pack txt > this (default: 30000)")
    ap.add_argument("--only-flagged", action="store_true",
                    help="hide clean rows")
    args = ap.parse_args()

    if not SESSIONS_ROOT.is_dir():
        print(f"no sessions dir at {SESSIONS_ROOT}", file=sys.stderr)
        return 2

    sessions = sorted(
        (p for p in SESSIONS_ROOT.iterdir() if p.is_dir()),
        reverse=True,
    )[: args.limit]

    flagged = 0
    clean = 0
    skipped_pre_f1 = 0
    print(f"{'session':<28}  {'task':<22}  {'plan':<10}  {'review':<10}  status")
    print("-" * 92)
    for sess in sessions:
        rows = scan_session(sess, args.min_bytes, args.max_bytes)
        if rows is None:
            skipped_pre_f1 += 1
            continue
        for row in rows:
            status = "OK" if not row["flags"] else "FLAG: " + ",".join(row["flags"])
            if row["flags"]:
                flagged += 1
            else:
                clean += 1
            if args.only_flagged and not row["flags"]:
                continue
            print(f"{sess.name:<28}  {row['task']:<22}  "
                  f"{row['plan']:<10}  {row['review']:<10}  {status}")
    print("-" * 92)
    summary = f"{flagged} flagged, {clean} clean"
    if skipped_pre_f1:
        summary += f", {skipped_pre_f1} pre-F1 (skipped)"
    summary += f" across {len(sessions)} sessions"
    print(summary)
    return 1 if flagged else 0


if __name__ == "__main__":
    sys.exit(main())
