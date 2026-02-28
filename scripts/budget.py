#!/usr/bin/env python3
"""
budget.py — Pre-call budget enforcement for Nightcrawler.

Usage:
    budget.py init <session_id> [--cap N]    Initialize budget for session
    budget.py check <session_id>             Check remaining budget
    budget.py log <session_id> <json>        Log an API call cost
    budget.py daily-total                    Get today's cumulative spend (UTC)
    budget.py monthly-total                  Get this month's cumulative spend (UTC)

Budget caps (configurable via env):
    NIGHTCRAWLER_SESSION_BUDGET=20.00
    NIGHTCRAWLER_DAILY_CAP=50.00
    NIGHTCRAWLER_MONTHLY_CAP=200.00
"""

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

STATE_DIR = Path(os.environ.get("NIGHTCRAWLER_STATE_PATH", "/home/nightcrawler/nightcrawler"))
RESERVE = 2.00

# Model pricing (USD per 1M tokens) — updated for current models
PRICING = {
    # Anthropic
    "claude-opus-4-6":   {"input": 5.00,  "output": 25.00, "cached_input": 0.50},
    "claude-sonnet-4-6": {"input": 3.00,  "output": 15.00, "cached_input": 0.30},
    # OpenAI
    "codex-mini-latest": {"input": 1.50,  "output": 6.00,  "cached_input": 0.375},
    "o4-mini":           {"input": 1.10,  "output": 4.40,  "cached_input": 0.275},
    "gpt-4o-mini":       {"input": 0.15,  "output": 0.60,  "cached_input": 0.075},
}


def cost_file(session_id: str) -> Path:
    return STATE_DIR / "sessions" / session_id / "cost.jsonl"


def budget_file(session_id: str) -> Path:
    return STATE_DIR / "sessions" / session_id / "budget.json"


def estimate_cost(model: str, input_tokens: int, output_tokens: int, cached_tokens: int = 0) -> float:
    """Estimate cost for a single API call."""
    p = PRICING.get(model)
    if not p:
        # Unknown model — use expensive estimate
        return (input_tokens * 15.0 + output_tokens * 75.0) / 1_000_000
    regular_input = input_tokens - cached_tokens
    cost = (regular_input * p["input"] + cached_tokens * p["cached_input"] + output_tokens * p["output"]) / 1_000_000
    return round(cost, 6)


def init_budget(session_id: str, cap: float = None):
    """Initialize budget tracking for a session."""
    if cap is None:
        cap = float(os.environ.get("NIGHTCRAWLER_SESSION_BUDGET", "20.00"))

    bfile = budget_file(session_id)
    bfile.parent.mkdir(parents=True, exist_ok=True)

    budget = {
        "session_id": session_id,
        "cap": cap,
        "reserve": RESERVE,
        "effective_cap": cap - RESERVE,
        "spent": 0.0,
        "effective_remaining": cap - RESERVE,
        "api_calls": 0,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    bfile.write_text(json.dumps(budget, indent=2))
    print(json.dumps(budget))


def check_budget(session_id: str):
    """Check current budget status."""
    bfile = budget_file(session_id)
    if not bfile.exists():
        print(json.dumps({"error": "No budget initialized", "session_id": session_id}))
        sys.exit(1)

    budget = json.loads(bfile.read_text())

    # Recalculate from cost.jsonl for accuracy
    cfile = cost_file(session_id)
    total_spent = 0.0
    call_count = 0
    if cfile.exists():
        for line in cfile.read_text().strip().split("\n"):
            if line.strip():
                entry = json.loads(line)
                total_spent += entry.get("cost_usd", 0)
                call_count += 1

    budget["spent"] = round(total_spent, 4)
    budget["api_calls"] = call_count
    budget["effective_remaining"] = round(budget["effective_cap"] - total_spent, 4)

    # Check daily cap
    daily = get_daily_total()
    budget["daily_spent"] = daily
    budget["daily_cap"] = float(os.environ.get("NIGHTCRAWLER_DAILY_CAP", "50.00"))
    budget["daily_remaining"] = round(budget["daily_cap"] - daily, 4)

    # Check monthly cap
    monthly = get_monthly_total()
    budget["monthly_spent"] = monthly
    budget["monthly_cap"] = float(os.environ.get("NIGHTCRAWLER_MONTHLY_CAP", "200.00"))
    budget["monthly_remaining"] = round(budget["monthly_cap"] - monthly, 4)

    # Status flags
    budget["can_continue"] = (
        budget["effective_remaining"] > 1.00
        and budget["daily_remaining"] > 0
        and budget["monthly_remaining"] > 0
    )
    budget["alert_80pct"] = budget["spent"] >= (budget["effective_cap"] * 0.80)

    # Save updated state
    bfile.write_text(json.dumps(budget, indent=2))
    print(json.dumps(budget))


def log_cost(session_id: str, cost_json: str):
    """Log an API call cost."""
    cfile = cost_file(session_id)
    cfile.parent.mkdir(parents=True, exist_ok=True)

    entry = json.loads(cost_json)
    entry["timestamp"] = datetime.now(timezone.utc).isoformat()

    # Calculate cost if not provided
    if "cost_usd" not in entry and "model" in entry:
        entry["cost_usd"] = estimate_cost(
            entry["model"],
            entry.get("input_tokens", 0),
            entry.get("output_tokens", 0),
            entry.get("cached_tokens", 0),
        )

    # Append to JSONL
    with open(cfile, "a") as f:
        f.write(json.dumps(entry) + "\n")
        f.flush()
        os.fsync(f.fileno())

    print(json.dumps(entry))


def get_daily_total() -> float:
    """Sum all session costs for today (UTC)."""
    today = datetime.now(timezone.utc).strftime("%Y%m%d")
    total = 0.0
    sessions_dir = STATE_DIR / "sessions"
    if sessions_dir.exists():
        for d in sessions_dir.iterdir():
            if d.is_dir() and d.name.startswith(today):
                cfile = d / "cost.jsonl"
                if cfile.exists():
                    for line in cfile.read_text().strip().split("\n"):
                        if line.strip():
                            total += json.loads(line).get("cost_usd", 0)
    return round(total, 4)


def get_monthly_total() -> float:
    """Sum all session costs for this month (UTC)."""
    month_prefix = datetime.now(timezone.utc).strftime("%Y%m")
    total = 0.0
    sessions_dir = STATE_DIR / "sessions"
    if sessions_dir.exists():
        for d in sessions_dir.iterdir():
            if d.is_dir() and d.name.startswith(month_prefix):
                cfile = d / "cost.jsonl"
                if cfile.exists():
                    for line in cfile.read_text().strip().split("\n"):
                        if line.strip():
                            total += json.loads(line).get("cost_usd", 0)
    return round(total, 4)


def pre_call_check(session_id: str, model: str, est_input: int, est_output: int) -> dict:
    """Pre-call budget gate. Returns whether the call should proceed."""
    bfile = budget_file(session_id)
    if not bfile.exists():
        return {"proceed": False, "reason": "no budget initialized"}

    budget = json.loads(bfile.read_text())

    # Recalculate spent
    cfile = cost_file(session_id)
    total_spent = 0.0
    if cfile.exists():
        for line in cfile.read_text().strip().split("\n"):
            if line.strip():
                total_spent += json.loads(line).get("cost_usd", 0)

    effective_remaining = budget["effective_cap"] - total_spent
    estimated_cost = estimate_cost(model, est_input, est_output)

    result = {
        "proceed": estimated_cost <= effective_remaining,
        "estimated_cost": estimated_cost,
        "effective_remaining": round(effective_remaining, 4),
        "model": model,
    }

    if not result["proceed"]:
        result["reason"] = f"Estimated cost ${estimated_cost:.4f} exceeds remaining ${effective_remaining:.4f}"

    return result


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "init":
        session_id = sys.argv[2]
        cap = float(sys.argv[3]) if len(sys.argv) > 3 else None
        init_budget(session_id, cap)

    elif cmd == "check":
        session_id = sys.argv[2]
        check_budget(session_id)

    elif cmd == "log":
        session_id = sys.argv[2]
        cost_json = sys.argv[3]
        log_cost(session_id, cost_json)

    elif cmd == "daily-total":
        print(json.dumps({"daily_total": get_daily_total()}))

    elif cmd == "monthly-total":
        print(json.dumps({"monthly_total": get_monthly_total()}))

    elif cmd == "pre-check":
        session_id = sys.argv[2]
        model = sys.argv[3]
        est_input = int(sys.argv[4])
        est_output = int(sys.argv[5])
        result = pre_call_check(session_id, model, est_input, est_output)
        print(json.dumps(result))

    else:
        print(f"Unknown command: {cmd}")
        print(__doc__)
        sys.exit(1)
