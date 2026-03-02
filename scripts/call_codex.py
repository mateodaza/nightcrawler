#!/usr/bin/env python3
"""
call_codex.py — Independent audit/review via Codex CLI (primary) or OpenAI API (fallback).

PRIMARY: Uses `codex review` CLI which runs gpt-5.3-codex — the best coding model.
FALLBACK: If CLI fails, falls back to OpenAI API with configurable model.

Usage:
    call_codex.py audit-plan --plan <path> --task-file <path> --rules <path> [--project <path>]
    call_codex.py review-impl --project <path> --plan <path> --rules <path> [--base <branch>]
    call_codex.py --test   (validate Codex CLI or API connectivity)

Reads OPENAI_API_KEY from environment.
Output format: JSON with {verdict: "APPROVED"|"REJECTED", feedback: "...", method: "cli"|"api", ...}
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    from openai import OpenAI
except ImportError:
    OpenAI = None

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

API_MODEL = os.environ.get("NIGHTCRAWLER_CODEX_MODEL", "o4-mini")
MAX_TOKENS = 1024
CLI_TIMEOUT = 120  # 2 minutes for CLI commands
STATE_DIR = Path(os.environ.get("NIGHTCRAWLER_STATE_PATH", "/home/nightcrawler/nightcrawler"))


# =============================================================================
# Codex CLI (primary) — uses gpt-5.3-codex
# =============================================================================

def codex_cli_available() -> bool:
    """Check if codex CLI is installed and responsive."""
    try:
        result = subprocess.run(
            ["codex", "--version"],
            capture_output=True, text=True, timeout=10
        )
        return result.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def codex_cli_review(project_path: str, review_prompt: str) -> dict:
    """Run codex exec with a review prompt including the diff.

    codex review --uncommitted does not accept custom prompts, so we use
    codex exec with full context (plan + rules + diff) instead.
    """
    return codex_cli_exec(review_prompt, project_path)


def codex_cli_exec(prompt: str, project_path: str = None) -> dict:
    """Run `codex exec` with a prompt for plan auditing (no file changes).

    Uses --full-auto for non-interactive execution with workspace-write sandbox.
    """
    cmd = ["codex", "exec", "--full-auto", prompt]

    try:
        result = subprocess.run(
            cmd,
            capture_output=True, text=True, timeout=CLI_TIMEOUT,
            cwd=project_path or os.getcwd(),
        )

        output = result.stdout.strip()
        if not output:
            output = result.stderr.strip()

        if not output:
            return {"content": "", "method": "cli", "model": "gpt-5.3-codex", "error": "empty output"}

        return {
            "content": output,
            "method": "cli",
            "model": "gpt-5.3-codex",
        }
    except subprocess.TimeoutExpired:
        return {"content": "", "method": "cli", "model": "gpt-5.3-codex", "error": "timeout"}
    except Exception as e:
        return {"content": "", "method": "cli", "model": "gpt-5.3-codex", "error": str(e)}


# =============================================================================
# OpenAI API (fallback)
# =============================================================================

def get_api_client():
    """Get OpenAI API client."""
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY not set")
    if OpenAI:
        return OpenAI(api_key=api_key)
    return None


def call_api(system_prompt: str, user_prompt: str, max_tokens: int = MAX_TOKENS) -> dict:
    """Make an API call. Returns {content, method, model, input_tokens, output_tokens, cost_usd}."""
    client = get_api_client()

    if client:
        # o4-mini and reasoning models use max_completion_tokens, not max_tokens
        model_params = {"model": API_MODEL, "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ]}
        if API_MODEL.startswith("o") or "codex" in API_MODEL:
            model_params["max_completion_tokens"] = max_tokens
        else:
            model_params["max_tokens"] = max_tokens
        response = client.chat.completions.create(**model_params)
        content = response.choices[0].message.content
        input_tokens = response.usage.prompt_tokens
        output_tokens = response.usage.completion_tokens
    else:
        import urllib.request
        api_key = os.environ["OPENAI_API_KEY"]
        req_body = {
            "model": API_MODEL,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
        }
        if API_MODEL.startswith("o") or "codex" in API_MODEL:
            req_body["max_completion_tokens"] = max_tokens
        else:
            req_body["max_tokens"] = max_tokens
        data = json.dumps(req_body).encode()
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

    # Estimate cost based on model
    pricing = {
        "o4-mini": (1.10, 4.40),
        "gpt-4o-mini": (0.15, 0.60),
        "codex-mini-latest": (1.50, 6.00),
    }
    in_price, out_price = pricing.get(API_MODEL, (1.50, 6.00))
    cost = (input_tokens * in_price + output_tokens * out_price) / 1_000_000

    return {
        "content": content,
        "method": "api",
        "model": API_MODEL,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "cached_tokens": 0,
        "cost_usd": round(cost, 6),
    }


# =============================================================================
# Verdict parsing
# =============================================================================

def parse_verdict(content: str) -> dict:
    """Parse APPROVED/REJECTED verdict from response."""
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


# =============================================================================
# Main commands
# =============================================================================

def _read_project_context(project_path: str) -> str:
    """Read project documentation to give the auditor full context."""
    context_parts = []
    if not project_path:
        return ""

    p = Path(project_path)
    # Read key documentation files
    for doc in ["RESEARCH.md", "PROGRESS.md", "TASK_QUEUE.md", "README.md"]:
        doc_path = p / doc
        if doc_path.exists():
            content = doc_path.read_text()
            # Truncate large files to keep prompt manageable
            if len(content) > 8000:
                content = content[:8000] + "\n\n... [TRUNCATED]"
            context_parts.append(f"--- {doc} ---\n{content}")

    # List existing source files so auditor knows what's already built
    src_dir = p / "src"
    if src_dir.exists():
        sol_files = sorted(src_dir.rglob("*.sol"))
        if sol_files:
            listing = "\n".join(f"  {f.relative_to(p)}" for f in sol_files)
            context_parts.append(f"--- Existing source files ---\n{listing}")

    return "\n\n".join(context_parts)


def audit_plan(plan_file: str, task_file: str, rules_file: str, project_path: str = None):
    """Audit a mini-plan. Tries Codex CLI exec first, falls back to API."""
    plan = Path(plan_file).read_text()
    task = Path(task_file).read_text()
    rules = Path(rules_file).read_text()
    project_context = _read_project_context(project_path)

    audit_prompt = f"""You are an independent code auditor for a Solidity/Foundry project. Review this implementation plan.

TASK REQUIREMENTS:
{task}

PROJECT RULES:
{rules}

PROJECT CONTEXT (spec, progress, existing code — use these to validate the plan):
{project_context}

MINI-PLAN TO AUDIT:
{plan}

PHILOSOPHY: The goal is fast iteration — get working code with sufficient quality. Humans handle hardening later. Your job is to catch things that would waste implementation cycles, not to polish the plan.

SEVERITY GUIDE — only REJECT for issues that would cause bugs or security flaws in the implementation:
- REJECT for: missing struct fields that exist in the spec, wrong types, missing security checks (reentrancy, access control, overflow), missing critical test cases, logic that contradicts the spec
- Do NOT reject for: style preferences, naming conventions, test verbosity, documentation completeness, minor organizational choices, theoretical edge cases the spec doesn't mention, gas optimization

If the plan covers all acceptance criteria and struct definitions correctly, APPROVE it even if you'd organize it differently.

Start your response with APPROVED or REJECTED.
If REJECTED, list ONLY the concrete issues with specific references to what's wrong and what the spec says. No vague concerns."""

    # Try CLI first
    if codex_cli_available():
        result = codex_cli_exec(audit_prompt, project_path)
        if result.get("content") and not result.get("error"):
            verdict = parse_verdict(result["content"])
            output = {
                **verdict,
                "method": "cli",
                "model": result["model"],
                "cost_usd": 0,  # CLI cost tracked by OpenAI account, not per-call
            }
            print(json.dumps(output))
            return

        print(f"CLI failed ({result.get('error', 'unknown')}), falling back to API", file=sys.stderr)

    # Fallback to API
    system_prompt = """You are an independent code auditor (Codex) for a Solidity/Foundry project.

YOUR ROLE:
- You audit implementation plans created by another AI model.
- Catch real bugs and security issues. Do not nitpick style or organization.
- The goal is fast iteration — get working code with sufficient quality. Humans handle hardening later.

WHAT WARRANTS REJECTION:
- Missing struct fields that exist in the spec, wrong types
- Missing security checks: reentrancy guards, access control, overflow protection
- Logic that contradicts the task requirements or spec
- Missing critical test cases for security-sensitive paths

WHAT DOES NOT WARRANT REJECTION:
- Style, naming, or organizational preferences
- Theoretical edge cases the spec doesn't mention
- Test verbosity or documentation completeness
- Minor structural choices that don't affect correctness

RESPONSE FORMAT:
Start with APPROVED or REJECTED.
If REJECTED, list ONLY concrete issues with spec references. No vague concerns.
Keep your response under 500 words."""

    user_prompt = f"""Audit this mini-plan against the task requirements and project rules.

TASK REQUIREMENTS:
{task}

PROJECT RULES:
{rules}

PROJECT CONTEXT (spec, progress, existing code — use these to validate the plan):
{project_context}

MINI-PLAN TO AUDIT:
{plan}

Is this plan ready for implementation? Reply APPROVED or REJECTED with specific feedback."""

    result = call_api(system_prompt, user_prompt)
    verdict = parse_verdict(result["content"])

    output = {
        **verdict,
        "method": result["method"],
        "model": result["model"],
        "input_tokens": result.get("input_tokens", 0),
        "output_tokens": result.get("output_tokens", 0),
        "cost_usd": result["cost_usd"],
    }
    print(json.dumps(output))


def review_impl(project_path: str, plan_file: str, rules_file: str, base_branch: str = None,
                diff_source: str = None, test_output_file: str = None):
    """Review implementation. Tries codex exec CLI first, falls back to API."""
    plan = Path(plan_file).read_text()
    rules = Path(rules_file).read_text()

    # Get diff for both CLI and API paths
    if diff_source:
        diff = Path(diff_source).read_text() if os.path.isfile(diff_source) else diff_source
    else:
        try:
            result_git = subprocess.run(
                ["git", "diff"], capture_output=True, text=True, cwd=project_path
            )
            diff = result_git.stdout
            if not diff:
                result_git = subprocess.run(
                    ["git", "diff", "--staged"], capture_output=True, text=True, cwd=project_path
                )
                diff = result_git.stdout
        except Exception:
            diff = "(could not read git diff)"

    if len(diff) > 80000:
        diff = diff[:40000] + "\n\n... [TRUNCATED] ...\n\n" + diff[-40000:]

    test_output = ""
    if test_output_file and os.path.isfile(test_output_file):
        test_output = Path(test_output_file).read_text()

    review_prompt = (
        f"You are an independent code reviewer for a Solidity/Foundry project. Review this implementation.\n\n"
        f"APPROVED PLAN:\n{plan[:3000]}\n\n"
        f"KEY RULES:\n{rules[:2000]}\n\n"
        f"GIT DIFF:\n```diff\n{diff[:30000]}\n```\n\n"
        f"TEST OUTPUT:\n```\n{test_output[:5000]}\n```\n\n"
        f"PHILOSOPHY: The goal is fast iteration — get working code with sufficient quality. Humans handle hardening later. "
        f"Your job is to catch real bugs, not suggest improvements.\n\n"
        f"SEVERITY GUIDE — only REJECT for issues that would cause real bugs or security flaws:\n"
        f"- REJECT for: reentrancy vulnerabilities, missing access control, integer overflow/underflow, "
        f"wrong state transitions, missing require checks the plan specified, tests that don't actually test what they claim, compilation errors\n"
        f"- Do NOT reject for: gas optimization, style/naming preferences, missing comments, "
        f"test organization, theoretical concerns not in the plan's scope\n\n"
        f"If the code implements the plan correctly, tests pass, and no security issues exist, APPROVE it.\n"
        f"Start your response with APPROVED or REJECTED. If REJECTED, list ONLY concrete bugs with file/line references."
    )

    # Try CLI first
    if codex_cli_available():
        result = codex_cli_review(project_path, review_prompt)
        if result.get("content") and not result.get("error"):
            verdict = parse_verdict(result["content"])
            output = {
                **verdict,
                "method": "cli",
                "model": result["model"],
                "cost_usd": 0,
            }
            print(json.dumps(output))
            return

        print(f"CLI failed ({result.get('error', 'unknown')}), falling back to API", file=sys.stderr)

    # Fallback to API (diff, test_output already fetched above)
    system_prompt = """You are an independent code reviewer (Codex) for a Solidity/Foundry project.

YOUR ROLE:
- You review implementations created by another AI model against the approved plan.
- The goal is fast iteration — get working code with sufficient quality. Humans handle hardening later.

WHAT WARRANTS REJECTION:
- Reentrancy vulnerabilities, missing access control, integer overflow/underflow
- Wrong state transitions or logic that contradicts the plan
- Missing require/revert checks the plan specified
- Tests that don't actually test what they claim, or compilation errors
- Code that deviates from the plan in ways that affect correctness

WHAT DOES NOT WARRANT REJECTION:
- Gas optimization suggestions
- Style, naming, or comment preferences
- Test organization or verbosity
- Theoretical concerns not in the plan's scope

RESPONSE FORMAT:
Start with APPROVED or REJECTED.
If REJECTED, list ONLY concrete bugs with file/line references. No style suggestions.
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
        "method": result["method"],
        "model": result["model"],
        "input_tokens": result.get("input_tokens", 0),
        "output_tokens": result.get("output_tokens", 0),
        "cost_usd": result["cost_usd"],
    }
    print(json.dumps(output))


def test_connectivity():
    """Test Codex CLI and API connectivity."""
    results = {}

    # Test CLI
    if codex_cli_available():
        cli_result = codex_cli_exec(
            "Reply with exactly: CODEX_CLI_OK",
        )
        if cli_result.get("content") and not cli_result.get("error"):
            results["cli"] = {"status": "ok", "model": "gpt-5.3-codex", "response": cli_result["content"][:100]}
        else:
            results["cli"] = {"status": "error", "error": cli_result.get("error", "empty output")}
    else:
        results["cli"] = {"status": "not_installed"}

    # Test API
    try:
        api_result = call_api(
            "You are a test assistant.",
            "Reply with exactly: CODEX_API_OK",
            max_tokens=10,
        )
        results["api"] = {"status": "ok", "model": API_MODEL, "cost_usd": api_result["cost_usd"]}
    except Exception as e:
        results["api"] = {"status": "error", "error": str(e)}

    # Overall status
    primary = results.get("cli", {}).get("status") == "ok"
    fallback = results.get("api", {}).get("status") == "ok"
    results["primary"] = "cli" if primary else ("api" if fallback else "none")
    results["ready"] = primary or fallback

    print(json.dumps(results, indent=2))
    if not results["ready"]:
        sys.exit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Call Codex for auditing (CLI primary, API fallback)")
    parser.add_argument("command", nargs="?", choices=["audit-plan", "review-impl"], default=None)
    parser.add_argument("--test", action="store_true")
    parser.add_argument("--plan")
    parser.add_argument("--task-file")
    parser.add_argument("--rules")
    parser.add_argument("--project")
    parser.add_argument("--diff")
    parser.add_argument("--test-output")
    parser.add_argument("--base")

    args = parser.parse_args()

    if args.test:
        test_connectivity()
    elif args.command == "audit-plan":
        audit_plan(args.plan, args.task_file, args.rules, args.project)
    elif args.command == "review-impl":
        review_impl(args.project, args.plan, args.rules, args.base, args.diff, args.test_output)
    else:
        parser.print_help()
        sys.exit(1)
