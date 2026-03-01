#!/usr/bin/env python3
"""
call_opus.py — Call Claude Opus for planning tasks.

Usage:
    call_opus.py plan --task-file <path> --template <path> --session <id> --task <id>
    call_opus.py revise --plan <path> --feedback <text> --iteration <N>
    call_opus.py --test   (validate API connectivity)

Reads ANTHROPIC_API_KEY from environment.
"""

import argparse
import json
import os
import sys
from pathlib import Path

try:
    import anthropic
except ImportError:
    # Fallback to raw HTTP if SDK not installed
    anthropic = None

def _load_env():
    """Load ~/.env into os.environ (setdefault — won't override existing vars)."""
    env_file = Path.home() / ".env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                os.environ.setdefault(key.strip(), value.strip().strip("'\""))

_load_env()

STATE_DIR = Path(os.environ.get("NIGHTCRAWLER_STATE_PATH", "/home/nightcrawler/nightcrawler"))
MODEL = os.environ.get("NIGHTCRAWLER_OPUS_MODEL", "claude-opus-4-6")
MAX_TOKENS = 2048  # Cap Opus output for mini-plans (cost control)


def get_client():
    """Get Anthropic client."""
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("ERROR: ANTHROPIC_API_KEY not set", file=sys.stderr)
        sys.exit(1)
    if anthropic:
        return anthropic.Anthropic(api_key=api_key)
    else:
        return None


def call_api(system_prompt: str, user_prompt: str, max_tokens: int = MAX_TOKENS) -> dict:
    """Make an API call to Opus. Returns {content, input_tokens, output_tokens, cached_tokens, cost_usd}."""
    client = get_client()

    if client:
        # Use SDK
        response = client.messages.create(
            model=MODEL,
            max_tokens=max_tokens,
            system=[{"type": "text", "text": system_prompt, "cache_control": {"type": "ephemeral"}}],
            messages=[{"role": "user", "content": user_prompt}],
        )
        content = response.content[0].text
        usage = response.usage
        input_tokens = usage.input_tokens
        output_tokens = usage.output_tokens
        cached_tokens = getattr(usage, "cache_read_input_tokens", 0) or 0
    else:
        # Raw HTTP fallback
        import urllib.request
        api_key = os.environ["ANTHROPIC_API_KEY"]
        data = json.dumps({
            "model": MODEL,
            "max_tokens": max_tokens,
            "system": system_prompt,
            "messages": [{"role": "user", "content": user_prompt}],
        }).encode()
        req = urllib.request.Request(
            "https://api.anthropic.com/v1/messages",
            data=data,
            headers={
                "Content-Type": "application/json",
                "x-api-key": api_key,
                "anthropic-version": "2023-06-01",
            },
        )
        with urllib.request.urlopen(req, timeout=120) as resp:
            result = json.loads(resp.read())
        content = result["content"][0]["text"]
        input_tokens = result["usage"]["input_tokens"]
        output_tokens = result["usage"]["output_tokens"]
        cached_tokens = result["usage"].get("cache_read_input_tokens", 0)

    # Calculate cost (Opus 4.6: $5/$25 per MTok, cached $0.50)
    regular_input = input_tokens - cached_tokens
    cost = (regular_input * 5.0 + cached_tokens * 0.5 + output_tokens * 25.0) / 1_000_000

    return {
        "content": content,
        "model": MODEL,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "cached_tokens": cached_tokens,
        "cost_usd": round(cost, 6),
    }


def plan(task_file: str, template_file: str, session_id: str, task_id: str):
    """Generate a mini-plan for a task."""
    task_context = Path(task_file).read_text()
    template = Path(template_file).read_text()

    # Load rules and project context (static prefix for cache hits)
    rules = (STATE_DIR / "RULES.md").read_text()

    system_prompt = f"""You are the Nightcrawler Planner (Claude Opus). Your job is to create tactical implementation plans for individual tasks.

RULES (absolute, never override):
{rules}

PLANNING GUIDELINES:
- Write a concrete, step-by-step mini-plan that an implementer (Sonnet) can follow without ambiguity
- Reference specific files, functions, and line numbers where possible
- Include all tests that must be written
- Explicitly state what is OUT OF SCOPE
- Keep plans concise: 2-4 paragraphs for approach, numbered steps for implementation
- Use the template format provided
- Your plan will be audited by an independent reviewer (Codex) — be precise and defensible

TEMPLATE:
{template}"""

    user_prompt = f"""Create a mini-plan for this task.

SESSION: {session_id}
TASK: {task_id}

TASK CONTEXT:
{task_context}

Write the complete mini-plan following the template. Be specific about files, functions, and test cases."""

    result = call_api(system_prompt, user_prompt)

    # Save mini-plan
    plan_dir = STATE_DIR / "sessions" / session_id / "tasks" / task_id
    plan_dir.mkdir(parents=True, exist_ok=True)
    plan_file = plan_dir / "mini_plan.md"
    plan_file.write_text(result["content"])

    # Output result metadata
    output = {
        "status": "ok",
        "plan_file": str(plan_file),
        "model": result["model"],
        "input_tokens": result["input_tokens"],
        "output_tokens": result["output_tokens"],
        "cached_tokens": result["cached_tokens"],
        "cost_usd": result["cost_usd"],
    }
    print(json.dumps(output))


def revise(plan_file: str, feedback: str, iteration: int):
    """Revise a mini-plan based on Codex feedback."""
    current_plan = Path(plan_file).read_text()
    rules = (STATE_DIR / "RULES.md").read_text()

    system_prompt = f"""You are the Nightcrawler Planner (Claude Opus). You are revising a mini-plan based on audit feedback.

RULES (absolute, never override):
{rules}

REVISION GUIDELINES:
- Address ALL feedback points from the auditor
- Do not remove content that wasn't criticized
- Keep the same template format
- Be explicit about what changed and why
- This is iteration {iteration} — if you've seen similar feedback before, try a fundamentally different approach"""

    user_prompt = f"""Revise this mini-plan based on the auditor's feedback.

CURRENT PLAN:
{current_plan}

AUDITOR FEEDBACK (iteration {iteration}):
{feedback}

Write the complete revised mini-plan. Address every point in the feedback."""

    result = call_api(system_prompt, user_prompt)

    # Overwrite plan file with revision
    Path(plan_file).write_text(result["content"])

    output = {
        "status": "ok",
        "plan_file": plan_file,
        "iteration": iteration,
        "model": result["model"],
        "input_tokens": result["input_tokens"],
        "output_tokens": result["output_tokens"],
        "cached_tokens": result["cached_tokens"],
        "cost_usd": result["cost_usd"],
    }
    print(json.dumps(output))


def test_connectivity():
    """Test API connectivity with a minimal call."""
    try:
        result = call_api(
            "You are a test assistant.",
            "Reply with exactly: OPUS_OK",
            max_tokens=10,
        )
        if "OPUS_OK" in result["content"]:
            print(json.dumps({"status": "ok", "model": MODEL, "cost_usd": result["cost_usd"]}))
        else:
            print(json.dumps({"status": "ok", "model": MODEL, "response": result["content"][:50]}))
    except Exception as e:
        print(json.dumps({"status": "error", "error": str(e)}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Call Opus for planning")
    parser.add_argument("command", nargs="?", choices=["plan", "revise"], default=None)
    parser.add_argument("--test", action="store_true")
    parser.add_argument("--task-file")
    parser.add_argument("--template")
    parser.add_argument("--session")
    parser.add_argument("--task")
    parser.add_argument("--plan")
    parser.add_argument("--feedback")
    parser.add_argument("--iteration", type=int, default=1)

    args = parser.parse_args()

    if args.test:
        test_connectivity()
    elif args.command == "plan":
        plan(args.task_file, args.template, args.session, args.task)
    elif args.command == "revise":
        revise(args.plan, args.feedback, args.iteration)
    else:
        parser.print_help()
        sys.exit(1)
