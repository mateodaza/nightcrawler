#!/usr/bin/env python3
"""
call_codex.py — Call OpenAI Codex-mini for independent audit/review.

Usage:
    call_codex.py audit-plan --plan <path> --task-file <path> --rules <path>
    call_codex.py review-impl --diff <text|path> --test-output <path> --plan <path> --rules <path>
    call_codex.py --test   (validate API connectivity)

Reads OPENAI_API_KEY from environment.
Output format: JSON with {verdict: "APPROVED"|"REJECTED", feedback: "...", ...}
"""

import argparse
import json
import os
import sys
from pathlib import Path

try:
    from openai import OpenAI
except ImportError:
    OpenAI = None

MODEL = os.environ.get("NIGHTCRAWLER_CODEX_MODEL", "gpt-4o-mini")
MAX_TOKENS = 1024  # Keep audits concise


def get_client():
    """Get OpenAI client."""
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        print("ERROR: OPENAI_API_KEY not set", file=sys.stderr)
        sys.exit(1)
    if OpenAI:
        return OpenAI(api_key=api_key)
    return None


def call_api(system_prompt: str, user_prompt: str, max_tokens: int = MAX_TOKENS) -> dict:
    """Make an API call to Codex. Returns {content, input_tokens, output_tokens, cost_usd}."""
    client = get_client()

    if client:
        response = client.chat.completions.create(
            model=MODEL,
            max_tokens=max_tokens,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
        )
        content = response.choices[0].message.content
        input_tokens = response.usage.prompt_tokens
        output_tokens = response.usage.completion_tokens
    else:
        # Raw HTTP fallback
        import urllib.request
        api_key = os.environ["OPENAI_API_KEY"]
        data = json.dumps({
            "model": MODEL,
            "max_tokens": max_tokens,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
        }).encode()
        req = urllib.request.Request(
            "https://api.openai.com/v1/chat/completions",
            data=data,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {api_key}",
            },
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            result = json.loads(resp.read())
        content = result["choices"][0]["message"]["content"]
        input_tokens = result["usage"]["prompt_tokens"]
        output_tokens = result["usage"]["completion_tokens"]

    # Calculate cost (codex-mini pricing)
    cost = (input_tokens * 1.5 + output_tokens * 6.0) / 1_000_000

    return {
        "content": content,
        "model": MODEL,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "cached_tokens": 0,
        "cost_usd": round(cost, 6),
    }


def parse_verdict(content: str) -> dict:
    """Parse APPROVED/REJECTED verdict from Codex response."""
    content_upper = content.upper()

    if "APPROVED" in content_upper:
        verdict = "APPROVED"
    elif "REJECTED" in content_upper:
        verdict = "REJECTED"
    else:
        verdict = "UNCLEAR"

    return {
        "verdict": verdict,
        "feedback": content,
    }


def audit_plan(plan_file: str, task_file: str, rules_file: str):
    """Audit a mini-plan for correctness and completeness."""
    plan = Path(plan_file).read_text()
    task = Path(task_file).read_text()
    rules = Path(rules_file).read_text()

    system_prompt = """You are an independent code auditor (Codex). You review implementation plans created by another AI model.

YOUR ROLE:
- You are NOT the planner. You audit the planner's work.
- Provide genuine, critical feedback. Do not rubber-stamp.
- Check: correctness, completeness, security, edge cases, test coverage, scope creep.
- You have NO allegiance to the planner. Your job is to catch what they missed.

RESPONSE FORMAT:
Start your response with exactly one of:
  APPROVED — if the plan is ready for implementation
  REJECTED — if the plan has issues that must be fixed

Then provide specific, actionable feedback. If REJECTED, list every issue that must be addressed.
Keep your response under 500 words."""

    user_prompt = f"""Audit this mini-plan against the task requirements and project rules.

TASK REQUIREMENTS:
{task}

PROJECT RULES:
{rules}

MINI-PLAN TO AUDIT:
{plan}

Is this plan ready for implementation? Reply APPROVED or REJECTED with specific feedback."""

    result = call_api(system_prompt, user_prompt)
    verdict = parse_verdict(result["content"])

    output = {
        **verdict,
        "model": result["model"],
        "input_tokens": result["input_tokens"],
        "output_tokens": result["output_tokens"],
        "cost_usd": result["cost_usd"],
    }
    print(json.dumps(output))


def review_impl(diff_source: str, test_output_file: str, plan_file: str, rules_file: str):
    """Review an implementation (git diff + test results) against the approved plan."""
    # diff_source can be inline text or a file path
    if os.path.isfile(diff_source):
        diff = Path(diff_source).read_text()
    else:
        diff = diff_source

    test_output = Path(test_output_file).read_text() if os.path.isfile(test_output_file) else test_output_file
    plan = Path(plan_file).read_text()
    rules = Path(rules_file).read_text()

    # Truncate diff if too long (keep under ~50K tokens input)
    if len(diff) > 80000:
        diff = diff[:40000] + "\n\n... [TRUNCATED — diff too large] ...\n\n" + diff[-40000:]

    system_prompt = """You are an independent code reviewer (Codex). You review implementations created by another AI model.

YOUR ROLE:
- You are NOT the implementer. You review their work.
- Check: does the code match the approved plan? Are tests comprehensive? Any bugs, security issues, or rule violations?
- Verify test output shows all tests passing.
- Check for: reentrancy issues, integer overflow, unchecked returns, missing access control.
- You have NO allegiance to the implementer.

RESPONSE FORMAT:
Start your response with exactly one of:
  APPROVED — if the implementation is correct and complete
  REJECTED — if there are issues that must be fixed

Then provide specific, actionable feedback. If REJECTED, list every issue with file/line references where possible.
Keep your response under 500 words."""

    user_prompt = f"""Review this implementation against the approved plan and project rules.

APPROVED PLAN:
{plan}

PROJECT RULES:
{rules}

GIT DIFF (changes made):
```diff
{diff}
```

TEST OUTPUT:
```
{test_output}
```

Is this implementation correct and complete? Reply APPROVED or REJECTED with specific feedback."""

    result = call_api(system_prompt, user_prompt)
    verdict = parse_verdict(result["content"])

    output = {
        **verdict,
        "model": result["model"],
        "input_tokens": result["input_tokens"],
        "output_tokens": result["output_tokens"],
        "cost_usd": result["cost_usd"],
    }
    print(json.dumps(output))


def test_connectivity():
    """Test API connectivity with a minimal call."""
    try:
        result = call_api(
            "You are a test assistant.",
            "Reply with exactly: CODEX_OK",
            max_tokens=10,
        )
        if "CODEX_OK" in result["content"]:
            print(json.dumps({"status": "ok", "model": MODEL, "cost_usd": result["cost_usd"]}))
        else:
            print(json.dumps({"status": "ok", "model": MODEL, "response": result["content"][:50]}))
    except Exception as e:
        print(json.dumps({"status": "error", "error": str(e)}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Call Codex for auditing")
    parser.add_argument("command", nargs="?", choices=["audit-plan", "review-impl"], default=None)
    parser.add_argument("--test", action="store_true")
    parser.add_argument("--plan")
    parser.add_argument("--task-file")
    parser.add_argument("--rules")
    parser.add_argument("--diff")
    parser.add_argument("--test-output")

    args = parser.parse_args()

    if args.test:
        test_connectivity()
    elif args.command == "audit-plan":
        audit_plan(args.plan, args.task_file, args.rules)
    elif args.command == "review-impl":
        review_impl(args.diff, args.test_output, args.plan, args.rules)
    else:
        parser.print_help()
        sys.exit(1)
