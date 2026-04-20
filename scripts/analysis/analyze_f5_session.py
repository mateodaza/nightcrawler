#!/usr/bin/env python3
"""Analyze a single Nightcrawler session for F5 (shipped_check) telemetry.

Usage:
    analyze_f5_session.py --session-dir /root/nightcrawler/sessions/<SESSION_ID>
    analyze_f5_session.py --session-dir <path> --json       # machine-readable

Inputs:
    <session-dir>/journal.jsonl
    <session-dir>/cost.jsonl            (phase-tagged after F5.4a)
    <session-dir>/tasks/<task_id>/shipped_check.json   (per-task detail)

Outputs a report covering:
    * F5 invocations: total count, verdict distribution, confidence distribution
    * Contract violations: counts + breakdown
    * Downstream dispatch: SHIPPED skips, PARTIAL injects, NOT_SHIPPED/UNCERTAIN proceeds
    * Cost: total F5 cost, per-call mean/p50/p95, token stats
    * Overhead: F5 cost as a percentage of total session Claude+Codex cost
    * Per-task detail table

Designed to fail softly — a session with NC_COMPANION_CHECK=0 (no F5 events)
produces a clean "F5 inactive" report, not a crash.

Intentional v1 limitation: precise per-call wall-clock latency is NOT
reported. The `shipped_check_complete` journal event carries no timestamp,
and inferring latency from cost.jsonl timestamps conflates F5 with free
pre-F5 operations (C0 scan, pick_next_task). Adding an explicit ts to the
journal event is a small TODO for v2.
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path
from typing import Any, Iterable


# ---------- helpers ---------------------------------------------------------

def read_jsonl(path: Path) -> list[dict[str, Any]]:
    """Read a jsonl file, skipping blank/unparseable lines. Missing file -> []."""
    if not path.is_file():
        return []
    rows: list[dict[str, Any]] = []
    for i, line in enumerate(path.read_text().splitlines(), start=1):
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            # Don't explode on a single malformed line — just skip and note.
            print(f"  warn: {path.name}:{i} malformed, skipping", file=sys.stderr)
    return rows


def pct(numer: float, denom: float) -> str:
    if denom == 0:
        return "n/a"
    return f"{(numer / denom) * 100:.2f}%"


def quantiles(values: list[float]) -> dict[str, float]:
    if not values:
        return {"mean": 0.0, "p50": 0.0, "p95": 0.0, "max": 0.0}
    s = sorted(values)
    # p95 with linear interp; for n<20 this collapses to the last element.
    p50 = statistics.median(s)
    if len(s) == 1:
        p95 = s[0]
    else:
        idx = (len(s) - 1) * 0.95
        lo = int(idx)
        hi = min(lo + 1, len(s) - 1)
        p95 = s[lo] + (s[hi] - s[lo]) * (idx - lo)
    return {
        "mean": statistics.fmean(s),
        "p50": p50,
        "p95": p95,
        "max": s[-1],
    }


def tally(items: Iterable[Any]) -> dict[str, int]:
    out: dict[str, int] = {}
    for x in items:
        key = str(x)
        out[key] = out.get(key, 0) + 1
    return out


# ---------- analysis --------------------------------------------------------

def analyze(session_dir: Path) -> dict[str, Any]:
    journal = read_jsonl(session_dir / "journal.jsonl")
    costs = read_jsonl(session_dir / "cost.jsonl")

    # Split journal by F5 event types.
    shipped_complete = [e for e in journal if e.get("event") == "shipped_check_complete"]
    shipped_skipped = [e for e in journal if e.get("event") == "shipped_check_skipped"]
    shipped_partial = [e for e in journal if e.get("event") == "shipped_check_partial_inject"]

    # Split cost by phase. Pre-F5.4a sessions will have all phase=None.
    f5_costs = [c for c in costs if c.get("phase") == "shipped_check"]
    total_cost = sum(c.get("cost_usd", 0) or 0 for c in costs)
    f5_cost_total = sum(c.get("cost_usd", 0) or 0 for c in f5_costs)

    # Per-task detail: enrich each completed event with its verdict file if present.
    tasks_dir = session_dir / "tasks"
    per_task: list[dict[str, Any]] = []
    for e in shipped_complete:
        tid = e.get("task_id") or "?"
        vj_path = tasks_dir / tid / "shipped_check.json"
        verdict_file: dict[str, Any] = {}
        if vj_path.is_file():
            try:
                verdict_file = json.loads(vj_path.read_text())
            except json.JSONDecodeError:
                verdict_file = {"_parse_error": True}
        # Matching cost entry for this task_id + phase=shipped_check
        tcost = [c for c in f5_costs if c.get("task_id") == tid]
        per_task.append({
            "task_id": tid,
            "verdict": e.get("verdict"),
            "confidence": e.get("confidence"),
            "violations": e.get("violations") or [],
            "evidence_count": e.get("evidence_count", 0),
            "open_questions_count": e.get("open_questions_count", 0),
            "ts": e.get("ts"),
            "latency_ms": e.get("latency_ms"),
            "model": verdict_file.get("model") or (tcost[0].get("model") if tcost else None),
            "input_tokens": tcost[0].get("input_tokens") if tcost else None,
            "output_tokens": tcost[0].get("output_tokens") if tcost else None,
            "cost_usd": tcost[0].get("cost_usd") if tcost else None,
            "method": verdict_file.get("method"),
            "summary": verdict_file.get("summary"),
            "dispatched": (
                "skipped" if any(s.get("task_id") == tid for s in shipped_skipped)
                else "partial_inject" if any(p.get("task_id") == tid for p in shipped_partial)
                else "proceed"
            ),
        })

    # Latency: F5.4c added latency_ms to shipped_check_complete. Older sessions
    # (pre-F5.4c) will be missing it — filter those out so they don't poison
    # the stats with zeros, and surface a count of missing samples.
    latency_values = [e.get("latency_ms") for e in shipped_complete
                      if isinstance(e.get("latency_ms"), (int, float))]
    latency_missing = len(shipped_complete) - len(latency_values)
    latency_quantiles = quantiles([float(v) for v in latency_values])
    # Check against PLAN-f5.md's <20s (20000ms) target.
    over_target = sum(1 for v in latency_values if v >= 20000)

    # Token stats for cost attribution checks.
    input_tokens = quantiles([c.get("input_tokens", 0) or 0 for c in f5_costs])
    output_tokens = quantiles([c.get("output_tokens", 0) or 0 for c in f5_costs])
    cost_quantiles = quantiles([c.get("cost_usd", 0) or 0 for c in f5_costs])

    # Aggregate contract violations across all F5 runs.
    all_violations: list[str] = []
    for e in shipped_complete:
        for v in (e.get("violations") or []):
            all_violations.append(v)

    return {
        "session_dir": str(session_dir),
        "journal_events": len(journal),
        "cost_entries": len(costs),
        "f5_active": bool(shipped_complete),
        "f5_invocations": len(shipped_complete),
        "verdicts": tally(e.get("verdict") for e in shipped_complete),
        "confidence": tally(e.get("confidence") for e in shipped_complete),
        "violations": tally(all_violations),
        "dispatch": {
            "skipped": len(shipped_skipped),
            "partial_inject": len(shipped_partial),
            "proceed": len(shipped_complete) - len(shipped_skipped) - len(shipped_partial),
        },
        "cost": {
            "f5_total_usd": round(f5_cost_total, 6),
            "session_total_usd": round(total_cost, 6),
            "overhead_pct": pct(f5_cost_total, total_cost),
            "per_call": {k: round(v, 6) for k, v in cost_quantiles.items()},
        },
        "tokens": {
            "input": {k: round(v, 1) for k, v in input_tokens.items()},
            "output": {k: round(v, 1) for k, v in output_tokens.items()},
        },
        "latency_ms": {
            "samples": len(latency_values),
            "missing": latency_missing,  # shipped_check_complete events without latency_ms (pre-F5.4c)
            "over_target_20s": over_target,
            **{k: round(v, 1) for k, v in latency_quantiles.items()},
        },
        "per_task": per_task,
    }


# ---------- rendering -------------------------------------------------------

def render_text(rpt: dict[str, Any]) -> str:
    out: list[str] = []
    w = out.append

    w(f"F5 telemetry — {rpt['session_dir']}")
    w(f"  journal events: {rpt['journal_events']}  cost entries: {rpt['cost_entries']}")
    w("")

    if not rpt["f5_active"]:
        w("F5 inactive: no shipped_check_complete events in journal.")
        w("(Session ran without NC_COMPANION_CHECK=1, or no eligible tasks.)")
        return "\n".join(out)

    w(f"F5 invocations: {rpt['f5_invocations']}")
    w("  verdicts:   " + ", ".join(f"{k}={v}" for k, v in rpt["verdicts"].items()))
    w("  confidence: " + ", ".join(f"{k}={v}" for k, v in rpt["confidence"].items()))
    if rpt["violations"]:
        w("  violations: " + ", ".join(f"{k}={v}" for k, v in rpt["violations"].items()))
    else:
        w("  violations: none")
    w("")

    d = rpt["dispatch"]
    w(f"Dispatch: skipped={d['skipped']}  partial_inject={d['partial_inject']}  proceed={d['proceed']}")
    w("")

    c = rpt["cost"]
    w(f"Cost: F5={c['f5_total_usd']} USD  session_total={c['session_total_usd']} USD  overhead={c['overhead_pct']}")
    pc = c["per_call"]
    w(f"  per-call USD: mean={pc['mean']}  p50={pc['p50']}  p95={pc['p95']}  max={pc['max']}")
    it, ot = rpt["tokens"]["input"], rpt["tokens"]["output"]
    w(f"  input tokens: mean={it['mean']:.0f}  p95={it['p95']:.0f}  max={it['max']:.0f}")
    w(f"  output tokens: mean={ot['mean']:.0f}  p95={ot['p95']:.0f}  max={ot['max']:.0f}")
    w("")

    lat = rpt["latency_ms"]
    if lat["samples"] > 0:
        w(f"Latency (ms): samples={lat['samples']}  mean={lat['mean']:.0f}  "
          f"p50={lat['p50']:.0f}  p95={lat['p95']:.0f}  max={lat['max']:.0f}")
        over = lat["over_target_20s"]
        target_line = f"  over 20s target: {over}/{lat['samples']}"
        if over == 0:
            target_line += "  (clean: all F5 calls within PLAN-f5.md <20s budget)"
        w(target_line)
        if lat["missing"]:
            w(f"  note: {lat['missing']} shipped_check_complete events missing "
              f"latency_ms (pre-F5.4c session data)")
    else:
        w("Latency: no samples with latency_ms (pre-F5.4c session, or all events missing the field)")
    w("")

    w("Per-task:")
    for t in rpt["per_task"]:
        tok = ""
        if t["input_tokens"] is not None:
            tok = f" in={t['input_tokens']} out={t['output_tokens']} ${t['cost_usd']:.5f}"
        latf = f" {t['latency_ms']}ms" if t.get("latency_ms") is not None else ""
        viol = f" violations={t['violations']}" if t["violations"] else ""
        summary = f" | {t['summary']}" if t["summary"] else ""
        w(f"  {t['task_id']:<12} {t['verdict']:<12} conf={t['confidence']:<6} "
          f"ev={t['evidence_count']} oq={t['open_questions_count']} "
          f"dispatch={t['dispatched']}{latf}{tok}{viol}{summary}")
    return "\n".join(out)


# ---------- cli -------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--session-dir", required=True, type=Path,
                   help="Path to session dir (contains journal.jsonl + cost.jsonl)")
    p.add_argument("--json", action="store_true",
                   help="Emit machine-readable JSON instead of a text report")
    args = p.parse_args()

    if not args.session_dir.is_dir():
        print(f"error: --session-dir not a directory: {args.session_dir}", file=sys.stderr)
        return 2

    rpt = analyze(args.session_dir)
    if args.json:
        print(json.dumps(rpt, indent=2, default=str))
    else:
        print(render_text(rpt))
    return 0


if __name__ == "__main__":
    sys.exit(main())
