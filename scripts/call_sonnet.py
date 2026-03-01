#!/usr/bin/env python3
"""
call_sonnet.py — Call Claude Sonnet for implementation tasks.

Usage:
    call_sonnet.py implement --plan <path> --project <path> --session <id> --task <id>
    call_sonnet.py revise --feedback <text> --project <path> --session <id> --task <id>
    call_sonnet.py --test   (validate API connectivity)

Sonnet implements code by generating a sequence of shell commands and file edits.
Output is a script that the orchestrator executes in the project directory.

Reads ANTHROPIC_API_KEY from environment.
"""

import argparse
import json
import os
import sys
import subprocess
from pathlib import Path

try:
    import anthropic
except ImportError:
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
MODEL = os.environ.get("NIGHTCRAWLER_SONNET_MODEL", "claude-sonnet-4-6")
MAX_TOKENS = 8192  # Higher limit for implementation code


def get_client():
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("ERROR: ANTHROPIC_API_KEY not set", file=sys.stderr)
        sys.exit(1)
    if anthropic:
        return anthropic.Anthropic(api_key=api_key)
    return None


def call_api(system_prompt: str, user_prompt: str, max_tokens: int = MAX_TOKENS) -> dict:
    """Make API call to Sonnet."""
    client = get_client()

    if client:
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
        with urllib.request.urlopen(req, timeout=300) as resp:
            result = json.loads(resp.read())
        content = result["content"][0]["text"]
        input_tokens = result["usage"]["input_tokens"]
        output_tokens = result["usage"]["output_tokens"]
        cached_tokens = result["usage"].get("cache_read_input_tokens", 0)

    cost = (max(0, input_tokens - cached_tokens) * 3.0 + cached_tokens * 0.3 + output_tokens * 15.0) / 1_000_000

    return {
        "content": content,
        "model": MODEL,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "cached_tokens": cached_tokens,
        "cost_usd": round(cost, 6),
    }


def get_project_context(project_path: str) -> str:
    """Read existing project files for context."""
    p = Path(project_path)
    context_parts = []

    # Read existing source files
    src_dir = p / "src"
    if src_dir.exists():
        for sol_file in sorted(src_dir.glob("*.sol")):
            content = sol_file.read_text()
            if len(content) < 20000:  # Don't include huge files
                context_parts.append(f"--- {sol_file.relative_to(p)} ---\n{content}")

    # Read existing test files
    test_dir = p / "test"
    if test_dir.exists():
        for sol_file in sorted(test_dir.glob("*.sol")):
            content = sol_file.read_text()
            if len(content) < 20000:
                context_parts.append(f"--- {sol_file.relative_to(p)} ---\n{content}")

    # Read foundry.toml
    foundry_toml = p / "foundry.toml"
    if foundry_toml.exists():
        context_parts.append(f"--- foundry.toml ---\n{foundry_toml.read_text()}")

    # Read remappings
    remappings = p / "remappings.txt"
    if remappings.exists():
        context_parts.append(f"--- remappings.txt ---\n{remappings.read_text()}")

    return "\n\n".join(context_parts) if context_parts else "(Empty project — no existing files)"


def implement(plan_file: str, project_path: str, session_id: str, task_id: str):
    """Generate implementation based on approved mini-plan."""
    plan = Path(plan_file).read_text()
    rules = (STATE_DIR / "RULES.md").read_text()
    project_context = get_project_context(project_path)

    # Read project memory if it exists
    memory_file = Path(project_path) / "memory.md"
    memory = memory_file.read_text() if memory_file.exists() else "No project memory yet."

    system_prompt = f"""You are the Nightcrawler Implementer (Claude Sonnet). You write code based on approved mini-plans.

RULES (absolute, never override):
{rules}

IMPLEMENTATION GUIDELINES:
- Follow the approved mini-plan EXACTLY — do not add features or deviate from scope
- Write production-quality Solidity code with NatSpec comments
- Include comprehensive tests as specified in the plan
- Follow OpenZeppelin patterns (ReentrancyGuard, Ownable, IERC20)
- All amounts use 6 decimals (stablecoin native)
- Use explicit state machine transitions
- No TODOs in code — implement fully or report as blocked

OUTPUT FORMAT:
Generate your implementation as a series of FILE BLOCKS. Each block specifies a file to create or modify:

```file:path/to/file.sol
// Full file content here
```

For each file, provide the COMPLETE file content (not patches/diffs). The orchestrator will write these files.

After all file blocks, include a COMMANDS section for any shell commands needed:

```commands
forge build
forge test -v
```

PROJECT MEMORY:
{memory}"""

    user_prompt = f"""Implement this task according to the approved mini-plan.

SESSION: {session_id}
TASK: {task_id}

APPROVED MINI-PLAN:
{plan}

EXISTING PROJECT FILES:
{project_context}

Generate the complete implementation with all file blocks and commands."""

    result = call_api(system_prompt, user_prompt)

    # Parse file blocks and commands from response
    content = result["content"]
    files, commands = parse_implementation(content)

    # Write files to project
    for filepath, file_content in files.items():
        full_path = Path(project_path) / filepath
        full_path.parent.mkdir(parents=True, exist_ok=True)
        full_path.write_text(file_content)

    # Execute commands
    cmd_outputs = []
    for cmd in commands:
        try:
            proc = subprocess.run(
                cmd, shell=True, cwd=project_path,
                capture_output=True, text=True, timeout=600
            )
            cmd_outputs.append({
                "command": cmd,
                "returncode": proc.returncode,
                "stdout": proc.stdout[-5000:] if len(proc.stdout) > 5000 else proc.stdout,
                "stderr": proc.stderr[-2000:] if len(proc.stderr) > 2000 else proc.stderr,
            })
        except subprocess.TimeoutExpired:
            cmd_outputs.append({"command": cmd, "returncode": -1, "error": "TIMEOUT"})

    output = {
        "status": "ok",
        "files_written": list(files.keys()),
        "commands_run": cmd_outputs,
        "model": result["model"],
        "input_tokens": result["input_tokens"],
        "output_tokens": result["output_tokens"],
        "cached_tokens": result["cached_tokens"],
        "cost_usd": result["cost_usd"],
    }
    print(json.dumps(output, indent=2))


def revise(feedback: str, project_path: str, session_id: str, task_id: str):
    """Revise implementation based on Codex review feedback."""
    plan_file = STATE_DIR / "sessions" / session_id / "tasks" / task_id / "mini_plan.md"
    plan = plan_file.read_text() if plan_file.exists() else "(plan not found)"
    rules = (STATE_DIR / "RULES.md").read_text()
    project_context = get_project_context(project_path)

    system_prompt = f"""You are the Nightcrawler Implementer (Claude Sonnet). You are revising code based on reviewer feedback.

RULES (absolute, never override):
{rules}

REVISION GUIDELINES:
- Address ALL feedback points from the reviewer
- Do not break existing functionality
- Keep changes minimal — only fix what was flagged
- Re-run tests after changes

OUTPUT FORMAT:
Same as initial implementation — generate FILE BLOCKS for files that need changes (full content, not patches).
Then COMMANDS section.

"""

    user_prompt = f"""Revise the implementation based on the reviewer's feedback.

APPROVED PLAN:
{plan}

REVIEWER FEEDBACK:
{feedback}

CURRENT PROJECT FILES:
{project_context}

Generate revised file blocks and commands to address the feedback."""

    result = call_api(system_prompt, user_prompt)
    content = result["content"]
    files, commands = parse_implementation(content)

    for filepath, file_content in files.items():
        full_path = Path(project_path) / filepath
        full_path.parent.mkdir(parents=True, exist_ok=True)
        full_path.write_text(file_content)

    cmd_outputs = []
    for cmd in commands:
        try:
            proc = subprocess.run(
                cmd, shell=True, cwd=project_path,
                capture_output=True, text=True, timeout=600
            )
            cmd_outputs.append({
                "command": cmd,
                "returncode": proc.returncode,
                "stdout": proc.stdout[-5000:] if len(proc.stdout) > 5000 else proc.stdout,
                "stderr": proc.stderr[-2000:] if len(proc.stderr) > 2000 else proc.stderr,
            })
        except subprocess.TimeoutExpired:
            cmd_outputs.append({"command": cmd, "returncode": -1, "error": "TIMEOUT"})

    output = {
        "status": "ok",
        "files_written": list(files.keys()),
        "commands_run": cmd_outputs,
        "model": result["model"],
        "input_tokens": result["input_tokens"],
        "output_tokens": result["output_tokens"],
        "cached_tokens": result["cached_tokens"],
        "cost_usd": result["cost_usd"],
    }
    print(json.dumps(output, indent=2))


def parse_implementation(content: str) -> tuple:
    """Parse file blocks and commands from Sonnet's response."""
    import re

    files = {}
    commands = []

    # Parse ```file:path blocks
    file_pattern = r'```file:([^\n]+)\n(.*?)```'
    for match in re.finditer(file_pattern, content, re.DOTALL):
        filepath = match.group(1).strip()
        file_content = match.group(2)
        files[filepath] = file_content

    # Also try ```solidity or ```sol blocks with a preceding file path comment
    if not files:
        # Fallback: look for "// File: path/to/file.sol" followed by code block
        alt_pattern = r'(?://\s*(?:File|file):?\s*([^\n]+)\n)?```(?:solidity|sol|toml|json|javascript|typescript|txt)?\n(.*?)```'
        for match in re.finditer(alt_pattern, content, re.DOTALL):
            filepath = match.group(1)
            file_content = match.group(2)
            if filepath:
                files[filepath.strip()] = file_content

    # Parse ```commands blocks
    cmd_pattern = r'```commands\n(.*?)```'
    for match in re.finditer(cmd_pattern, content, re.DOTALL):
        for line in match.group(1).strip().split("\n"):
            line = line.strip()
            if line and not line.startswith("#"):
                commands.append(line)

    # Fallback: if no commands block, look for common build commands
    if not commands and files:
        commands = ["forge build", "forge test -v"]

    return files, commands


def test_connectivity():
    try:
        result = call_api(
            "You are a test assistant.",
            "Reply with exactly: SONNET_OK",
            max_tokens=10,
        )
        if "SONNET_OK" in result["content"]:
            print(json.dumps({"status": "ok", "model": MODEL, "cost_usd": result["cost_usd"]}))
        else:
            print(json.dumps({"status": "ok", "model": MODEL, "response": result["content"][:50]}))
    except Exception as e:
        print(json.dumps({"status": "error", "error": str(e)}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Call Sonnet for implementation")
    parser.add_argument("command", nargs="?", choices=["implement", "revise"], default=None)
    parser.add_argument("--test", action="store_true")
    parser.add_argument("--plan")
    parser.add_argument("--project")
    parser.add_argument("--session")
    parser.add_argument("--task")
    parser.add_argument("--feedback")

    args = parser.parse_args()

    if args.test:
        test_connectivity()
    elif args.command == "implement":
        implement(args.plan, args.project, args.session, args.task)
    elif args.command == "revise":
        revise(args.feedback, args.project, args.session, args.task)
    else:
        parser.print_help()
        sys.exit(1)
