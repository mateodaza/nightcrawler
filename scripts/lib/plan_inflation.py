#!/usr/bin/env python3
"""B4.1: Plan inflation detector (observe-only).

Runs between audit-rejection and revise_plan() in the plan loop. Tracks
per-task plan_history.jsonl with one entry per rejection:
    {iter, size_bytes, top_blocker_hash, top_blocker_subject,
     top_blocker_raw, ts}

Fires `plan_inflation_detected` to stdout (single-line JSON, suitable for
piping into `journal`) when ANY of:
    - current plan size >= 1.5x initial (first rejection's size)
    - current plan size >= 1.4x prior rejection's size
    - current top_blocker hash matches any prior rejection's hash

If nothing fires, stdout is empty. The history file is always appended —
non-firing rows are kept only in per-task plan_history.jsonl, NOT in the
global journal (keeps the global journal clean for fired events only).

B4.1 is pure telemetry: no steering, no flag needed. The steering sibling
B4.2 lands behind NC_PLAN_INFLATION_GUARD=1 once B4.1 validates on one
natural session.

Thresholds rationale (1.5x / 1.4x): conservative for a detector. NC-413
went 14.2KB -> 17.8KB -> 21.7KB -> 25.9KB -> 28.6KB: every revision above
iter-1 would have tripped 1.4x-prior, and iters 4-5 would have tripped
1.5x-initial. Those are exactly the cases we want flagged.

Usage:
    plan_inflation.py \\
        --task-id NC-413 \\
        --iter 3 \\
        --plan-file /path/to/mini_plan.md \\
        --history-file /path/to/plan_history.jsonl \\
        --blocker-json '[{"issue":"...","severity":"high"}]'

Exit codes:
    0 always. Errors print to stderr; stdout stays empty on error so the
    caller's `journal` never records a bogus event.
"""
import argparse
import datetime as _dt
import hashlib
import json
import os
import re
import sys

# Tunable thresholds — kept as constants so B4.2 can reuse the same numbers.
SIZE_VS_INITIAL_MULT = 1.5
SIZE_VS_PRIOR_MULT   = 1.4

_WS_RE = re.compile(r"\s+")
_PUNCT_RE = re.compile(r"[^\w\s]")


def _now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _extract_top_blocker_raw(blocker_json: str) -> str:
    """Pull the first blocker's human-facing text out of AUDIT_BLOCKING_JSON.

    The v2 audit contract's blocking_issues is a list. Each entry is usually
    an object with a text field; be defensive about the exact key.
    Returns "" when the list is empty or the JSON is malformed.
    """
    if not blocker_json:
        return ""
    try:
        items = json.loads(blocker_json)
    except (ValueError, TypeError):
        return ""
    if not isinstance(items, list) or not items:
        return ""
    first = items[0]
    if isinstance(first, str):
        return first.strip()
    if isinstance(first, dict):
        for k in ("issue", "subject", "description", "text", "message", "title"):
            v = first.get(k)
            if isinstance(v, str) and v.strip():
                return v.strip()
        # Fallback: serialize the dict so we still get a stable hash.
        try:
            return json.dumps(first, sort_keys=True)
        except (TypeError, ValueError):
            return ""
    return str(first).strip()


def _normalize(text: str) -> str:
    """Lowercase, strip punctuation, collapse whitespace."""
    if not text:
        return ""
    lower = text.lower()
    stripped = _PUNCT_RE.sub(" ", lower)
    return _WS_RE.sub(" ", stripped).strip()


def _hash(normalized: str) -> str:
    if not normalized:
        return ""
    return hashlib.sha1(normalized.encode("utf-8")).hexdigest()[:16]


def _read_history(path: str):
    if not path or not os.path.exists(path):
        return []
    out = []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except (ValueError, TypeError):
                    # Skip corrupted lines rather than abort — keeps
                    # inflation detection best-effort.
                    continue
    except OSError as exc:
        print(f"plan_inflation: failed to read history {path}: {exc}",
              file=sys.stderr)
    return out


def _append_history(path: str, entry: dict) -> None:
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry) + "\n")
    except OSError as exc:
        print(f"plan_inflation: failed to append history {path}: {exc}",
              file=sys.stderr)


def _file_size(path: str) -> int:
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--task-id", required=True)
    ap.add_argument("--iter", type=int, required=True,
                    help="iteration number of the just-rejected plan (1-based)")
    ap.add_argument("--plan-file", required=True,
                    help="path to the rejected mini_plan.md whose size we measure")
    ap.add_argument("--history-file", required=True,
                    help="path to per-task plan_history.jsonl (created if absent)")
    ap.add_argument("--blocker-json", default="",
                    help="AUDIT_BLOCKING_JSON (JSON string of blocking_issues array)")
    args = ap.parse_args()

    current_size = _file_size(args.plan_file)
    raw = _extract_top_blocker_raw(args.blocker_json)
    normalized = _normalize(raw)
    blocker_hash = _hash(normalized)

    history = _read_history(args.history_file)

    initial_size = history[0]["size_bytes"] if history else current_size
    prior_size   = history[-1]["size_bytes"] if history else current_size

    # Fire decisions. Each is independent; reason is an OR of the fired ones.
    fired_size_initial = bool(history) and initial_size > 0 and \
        current_size >= SIZE_VS_INITIAL_MULT * initial_size
    fired_size_prior = bool(history) and prior_size > 0 and \
        current_size >= SIZE_VS_PRIOR_MULT * prior_size

    repeated_blocker = False
    if blocker_hash:
        for prev in history:
            if prev.get("top_blocker_hash") == blocker_hash:
                repeated_blocker = True
                break

    fired = fired_size_initial or fired_size_prior or repeated_blocker

    reason_parts = []
    if fired_size_initial or fired_size_prior:
        reason_parts.append("size")
    if repeated_blocker:
        reason_parts.append("repeat")
    reason = "+".join(reason_parts) if reason_parts else "none"

    # Always append the rejection entry to per-task history, even when
    # nothing fires. The global journal gets the event only on a fire.
    entry = {
        "iter": args.iter,
        "size_bytes": current_size,
        "top_blocker_hash": blocker_hash,
        "top_blocker_subject": normalized,
        "top_blocker_raw": raw,
        "ts": _now_iso(),
    }
    _append_history(args.history_file, entry)

    if not fired:
        return 0

    def _pct(cur: int, base: int) -> int:
        if base <= 0:
            return 0
        return int(round((cur - base) * 100.0 / base))

    event = {
        "event": "plan_inflation_detected",
        "task_id": args.task_id,
        "iteration": args.iter,
        "initial_size_bytes": initial_size,
        "prior_size_bytes": prior_size,
        "current_size_bytes": current_size,
        "growth_from_initial_pct": _pct(current_size, initial_size),
        "growth_from_prior_pct":   _pct(current_size, prior_size),
        "repeated_blocker": repeated_blocker,
        "blocker_subject": normalized[:160],
        "reason": reason,
        "steer_injected": False,
        "ts": entry["ts"],
    }
    # Single-line JSON on stdout — ready for nightcrawler.sh's journal().
    print(json.dumps(event))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
