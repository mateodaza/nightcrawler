#!/usr/bin/env python3
"""
call_codex.py — Independent audit/review via Codex CLI (primary) or OpenAI API (fallback).

PRIMARY: Uses `codex review` CLI which runs gpt-5.4 — the best coding model.
FALLBACK: If CLI fails, falls back to OpenAI API with configurable model.

Usage:
    call_codex.py audit-plan --plan <path> --task-file <path> --rules <path> [--project <path>]
    call_codex.py review-impl --project <path> --plan <path> --rules <path> [--base <branch>]
    call_codex.py --test   (validate Codex CLI or API connectivity)
    call_codex.py --parse-test   (read JSON/text from stdin, emit structured output; no LLM call)

Reads OPENAI_API_KEY from environment.

Output format (v2 contract, schema_version: 2):
    {
        "verdict": "APPROVED" | "REJECTED",
        "blocking_issues": [{reference, current_state, required_change, severity}],
        "advisories": [{note, rationale}],
        "irrelevant": [{note, why_skipped}],
        "complexity_tier": "TRIVIAL" | "STANDARD" | "RISKY" | "UNKNOWN",
        "confidence": "high" | "medium" | "low" | "unknown",
        "why_confident": "...",
        "what_would_change_my_mind": "...",
        "schema_version": 2,

        // Back-compat — keeps existing nightcrawler.sh consumers working:
        "feedback": "<human-readable rendering>",

        // Metadata:
        "method": "cli" | "api",
        "model": "...",
        "cost_usd": ...,
        "input_tokens": ..., "output_tokens": ...,

        // Contract-enforcement telemetry (only present when fired):
        "contract_violations": ["vague_rejection_coerced" | "unparseable_v2" | ...]
    }
"""

import argparse
import json
import os
import re
import subprocess
import sys
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
STATE_DIR = Path(os.environ.get("NIGHTCRAWLER_STATE_PATH", str(Path.home() / ".nightcrawler")))
SCHEMA_VERSION = 2

# Config dir lives next to scripts/ (SCRIPTS_DIR/../config/projects/<name>/audit-persona.md)
SCRIPTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS_DIR.parent
CONFIG_DIR = REPO_ROOT / "config"


# =============================================================================
# Persona loading
# =============================================================================

_GENERIC_PERSONA = """You are an independent code auditor.

## What warrants REJECT (blocking_issues)
- Logic that contradicts the task acceptance criteria or spec.
- Missing required fields, wrong types, missing security/authorization checks the task calls out.
- Migration or schema changes that risk data loss or integrity.
- Tests that don't actually test what they claim.

## What does NOT warrant reject (advisories at most)
- Style, naming, organisation preferences.
- Missing comments or documentation.
- Theoretical edge cases the spec doesn't mention.
- Refactors the auditor would have done differently.

## Philosophy
Fast iteration, not polish. The planner and implementer are constrained AI models; your job is to catch real bugs and spec violations, not to reshape style. If the implementation satisfies the task's acceptance criteria and doesn't introduce a correctness regression, APPROVE it.

If you cannot articulate a concrete `required_change`, the concern belongs in `advisories`, not `blocking_issues`.
"""


def _load_audit_persona(project_path: str) -> str:
    """Read audit-persona.md for the project, fall back to a generic persona.

    Project name is the basename of project_path. Looks up
    config/projects/<name>/audit-persona.md relative to the repo root.
    """
    if not project_path:
        return _GENERIC_PERSONA
    project_name = Path(project_path).name
    persona_path = CONFIG_DIR / "projects" / project_name / "audit-persona.md"
    if persona_path.exists():
        return persona_path.read_text()
    return _GENERIC_PERSONA


# =============================================================================
# Structured contract
# =============================================================================

def _schema_instructions() -> str:
    """Return the JSON contract instructions appended to every prompt."""
    return f"""
RESPONSE FORMAT — return a single JSON object and NOTHING ELSE. No prose, no markdown fences, no preamble.

{{
  "verdict": "APPROVED" | "REJECTED",
  "blocking_issues": [
    {{
      "reference": "acceptance-criteria line or spec pointer",
      "current_state": "what the plan/impl does today",
      "required_change": "concrete file/line or function-level change",
      "severity": "high" | "medium"
    }}
  ],
  "advisories": [{{"note": "...", "rationale": "..."}}],
  "irrelevant": [{{"note": "...", "why_skipped": "..."}}],
  "complexity_tier": "TRIVIAL" | "STANDARD" | "RISKY",
  "confidence": "high" | "medium" | "low",
  "why_confident": "one or two sentences",
  "what_would_change_my_mind": "one or two sentences",
  "schema_version": {SCHEMA_VERSION}
}}

RULES:
- `APPROVED` ships. Empty `blocking_issues` is required for APPROVED.
- If you cannot articulate a concrete `required_change` (specific file/line or function), the concern belongs in `advisories`, not `blocking_issues`. REJECT with vague concerns will be coerced to APPROVED.
- `irrelevant[]` enumerates things you considered and chose not to flag — this is calibration data, list 0–3 items max.
- `complexity_tier` is your observation; the orchestrator owns loop iteration caps regardless.

CONFIDENCE — use it honestly, not as hedging:
- "high"   — you can cite the specific file/line/AC that justifies the verdict.
- "medium" — you have a working theory but one important piece is inferred, not observed.
- "low"    — the decisive evidence is not in the pack (e.g. the file the task centres on is missing), or you had to guess at intent.
  REJECTED + confidence=low + no concrete blocking_issues will be coerced to APPROVED with an advisory.
  Do not REJECT just because the pack was thin — say so in `what_would_change_my_mind` and advise instead.
""".strip()


# Shape of an empty-but-valid v2 response.
def _empty_v2(verdict: str = "APPROVED") -> dict:
    return {
        "verdict": verdict,
        "blocking_issues": [],
        "advisories": [],
        "irrelevant": [],
        "complexity_tier": "UNKNOWN",
        "confidence": "unknown",
        "why_confident": "",
        "what_would_change_my_mind": "",
        "schema_version": SCHEMA_VERSION,
    }


_JSON_OBJECT_RE = re.compile(r"\{[\s\S]*\}")


def _extract_json_object(content: str):
    """Return the first parseable JSON object in content, or None.

    Handles responses that wrap JSON in ```json ... ``` fences or in prose.
    Strategy: strip fences, then try progressively larger candidate slices
    starting at the first '{' and working outward.
    """
    if not content:
        return None

    # Strip common fencing
    stripped = content.strip()
    if stripped.startswith("```"):
        # Remove a leading ```lang and trailing ```
        stripped = re.sub(r"^```[a-zA-Z]*\n?", "", stripped)
        stripped = re.sub(r"\n?```\s*$", "", stripped)

    # Fast path — whole thing is JSON
    try:
        obj = json.loads(stripped)
        if isinstance(obj, dict):
            return obj
    except Exception:
        pass

    # Slow path — find the largest {...} block that parses
    m = _JSON_OBJECT_RE.search(stripped)
    if not m:
        return None
    candidate = m.group(0)
    # Try shrinking from the right until parseable
    while candidate:
        try:
            obj = json.loads(candidate)
            if isinstance(obj, dict):
                return obj
        except Exception:
            pass
        # Drop the last char and try again, up to a point
        candidate = candidate[:-1]
        if len(candidate) < 2:
            return None
    return None


def _render_feedback(v2: dict) -> str:
    """Render a v2 response as the legacy free-form feedback string.

    This keeps nightcrawler.sh's existing `AUDIT_FEEDBACK`/`REVIEW_FEEDBACK`
    readers + `check_impl_lock` regex matcher working unchanged.
    """
    verdict = v2.get("verdict", "UNCLEAR")
    lines = [verdict]

    blocking = v2.get("blocking_issues") or []
    if blocking:
        lines.append("")
        lines.append("BLOCKING ISSUES:")
        for i, issue in enumerate(blocking, 1):
            ref = issue.get("reference", "")
            cur = issue.get("current_state", "")
            req = issue.get("required_change", "")
            sev = issue.get("severity", "")
            header = f"{i}. [{sev}] {ref}" if sev else f"{i}. {ref}"
            lines.append(header)
            if cur:
                lines.append(f"   current: {cur}")
            if req:
                lines.append(f"   required: {req}")

    advisories = v2.get("advisories") or []
    if advisories:
        lines.append("")
        lines.append("ADVISORIES:")
        for adv in advisories:
            note = adv.get("note", "")
            rationale = adv.get("rationale", "")
            if note:
                lines.append(f"- {note}" + (f" — {rationale}" if rationale else ""))

    return "\n".join(lines).strip()


def parse_structured_verdict(content: str) -> dict:
    """Parse an auditor response into the v2 contract shape.

    Contract enforcement:
    - REJECTED with empty blocking_issues → coerced to APPROVED, advisory added,
      contract_violations includes "vague_rejection_coerced".
    - Unparseable JSON → fall back to v1 parse, mark schema_version=1,
      contract_violations includes "unparseable_v2".

    Returns a dict that always includes the v2 fields + a rendered `feedback` for
    legacy consumers.
    """
    obj = _extract_json_object(content or "")
    violations = []

    if obj is None or not isinstance(obj, dict) or "verdict" not in obj:
        # v1 fallback — look for APPROVED/REJECTED in free text
        v1 = _empty_v2()
        upper = (content or "").upper()
        if "APPROVED" in upper and "REJECTED" not in upper:
            v1["verdict"] = "APPROVED"
        elif "REJECTED" in upper:
            v1["verdict"] = "REJECTED"
            # Stuff the whole content into a single blocking issue so downstream
            # regex matchers on `feedback` still see the raw failure text.
            v1["blocking_issues"] = [{
                "reference": "parser fallback",
                "current_state": "auditor did not return v2 JSON",
                "required_change": (content or "").strip()[:4000],
                "severity": "medium",
            }]
        else:
            v1["verdict"] = "UNCLEAR"
        v1["schema_version"] = 1
        violations.append("unparseable_v2")
        v1["contract_violations"] = violations
        v1["feedback"] = _render_feedback(v1) or (content or "").strip()
        return v1

    # Normalise into the full v2 shape — missing fields default, extras preserved.
    v2 = _empty_v2()
    v2.update({
        "verdict": str(obj.get("verdict", "UNCLEAR")).upper(),
        "blocking_issues": list(obj.get("blocking_issues") or []),
        "advisories": list(obj.get("advisories") or []),
        "irrelevant": list(obj.get("irrelevant") or []),
        "complexity_tier": str(obj.get("complexity_tier", "UNKNOWN")).upper(),
        "confidence": str(obj.get("confidence", "unknown")).lower(),
        "why_confident": str(obj.get("why_confident", "") or ""),
        "what_would_change_my_mind": str(obj.get("what_would_change_my_mind", "") or ""),
        "schema_version": int(obj.get("schema_version", SCHEMA_VERSION) or SCHEMA_VERSION),
    })

    # Coercion rule: REJECTED with empty blocking_issues is a vague rejection.
    # F2: if confidence is also 'low', tag it separately — that signals the
    # reviewer bailed on a thin pack rather than hedging on a hunch.
    if v2["verdict"] == "REJECTED" and not v2["blocking_issues"]:
        v2["verdict"] = "APPROVED"
        is_low_conf = v2["confidence"] == "low"
        rationale = (
            "Coerced to APPROVED per contract — low-confidence rejection with no "
            "concrete blocking_issues; likely a thin pack rather than a real blocker."
            if is_low_conf else
            "Coerced to APPROVED per contract — vague concerns must be advisories, not blockers."
        )
        v2["advisories"] = v2["advisories"] + [{
            "note": "Auditor returned REJECTED with no concrete blocking_issues.",
            "rationale": rationale,
        }]
        violations.append("vague_rejection_coerced")
        if is_low_conf:
            violations.append("low_confidence_unfounded_rejection")

    if violations:
        v2["contract_violations"] = violations

    v2["feedback"] = _render_feedback(v2)
    return v2


# =============================================================================
# Codex CLI (primary) — uses gpt-5.4
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


def codex_cli_exec(prompt: str, project_path: str = None) -> dict:
    """Run `codex exec` with a prompt. No file changes; workspace-write sandbox."""
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
            return {"content": "", "method": "cli", "model": "gpt-5.4", "error": "empty output"}

        return {
            "content": output,
            "method": "cli",
            "model": "gpt-5.4",
        }
    except subprocess.TimeoutExpired:
        return {"content": "", "method": "cli", "model": "gpt-5.4", "error": "timeout"}
    except Exception as e:
        return {"content": "", "method": "cli", "model": "gpt-5.4", "error": str(e)}


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
# Project context
# =============================================================================

def _read_project_context(project_path: str) -> str:
    """Read project documentation to give the auditor full context."""
    context_parts = []
    if not project_path:
        return ""

    p = Path(project_path)
    for doc in ["RESEARCH.md", "PROGRESS.md", "TASK_QUEUE.md", "README.md"]:
        doc_path = p / doc
        if doc_path.exists():
            content = doc_path.read_text()
            if len(content) > 8000:
                content = content[:8000] + "\n\n... [TRUNCATED]"
            context_parts.append(f"--- {doc} ---\n{content}")

    # Source-file listing — pattern is project-specific.
    src_dir = p / "src"
    if src_dir.exists():
        # Solidity for clout; TS/TSX for camello-style projects. Pick whichever exists.
        sol_files = sorted(src_dir.rglob("*.sol"))
        if sol_files:
            listing = "\n".join(f"  {f.relative_to(p)}" for f in sol_files[:200])
            context_parts.append(f"--- Existing source files ---\n{listing}")
        else:
            ts_files = sorted(list(src_dir.rglob("*.ts")) + list(src_dir.rglob("*.tsx")))
            if ts_files:
                listing = "\n".join(f"  {f.relative_to(p)}" for f in ts_files[:200])
                context_parts.append(f"--- Existing source files ---\n{listing}")

    return "\n\n".join(context_parts)


# =============================================================================
# Relevance pack (F1) — replaces `_read_project_context` when flag is on
# =============================================================================

def _maybe_build_pack(*, project_path: str, task_text: str, task_id: str,
                      phase: str, session_dir: str = None,
                      changed_files: list = None) -> tuple:
    """Build a relevance pack if NC_RELEVANCE_PACK=1; else return (None, None).

    Returns (pack_text, meta_path). pack_text replaces project_context in the
    assembled prompt; meta_path is the sidecar JSON for debugging (for stderr
    log only — not passed to the model).
    """
    if os.environ.get("NC_RELEVANCE_PACK") != "1":
        return None, None

    # lib/ is a sibling directory of this file; ensure it's importable.
    lib_dir = SCRIPTS_DIR
    if str(lib_dir) not in sys.path:
        sys.path.insert(0, str(lib_dir))
    try:
        from lib import relevance_pack  # type: ignore
    except ImportError as exc:
        print(f"NC_RELEVANCE_PACK=1 but lib/relevance_pack import failed: {exc}",
              file=sys.stderr)
        return None, None

    artifact_dir = None
    state_dir = os.environ.get("NIGHTCRAWLER_STATE_PATH")
    if session_dir:
        artifact_dir = str(Path(session_dir) / "relevance-packs")
        # SESSION_DIR is <STATE_DIR>/sessions/<SESSION_ID> — recover state_dir
        # if not passed explicitly via env.
        if not state_dir:
            try:
                state_dir = str(Path(session_dir).resolve().parent.parent)
            except OSError:
                state_dir = None

    try:
        pack = relevance_pack.build_pack(
            task_text=task_text,
            task_id=task_id or "unknown",
            phase=phase,
            project_path=project_path or ".",
            state_dir=state_dir,
            artifact_dir=artifact_dir,
            changed_files=changed_files,
            current_session_dir=session_dir,
        )
    except Exception as exc:  # defensive — never let the pack break audits
        print(f"relevance pack build failed ({exc}); falling back to project_context",
              file=sys.stderr)
        return None, None

    return pack["text"], pack["artifacts"].get("meta_path")


def _maybe_log_prompt(label: str, prompt: str) -> None:
    """Dump the assembled prompt to stderr when NC_LOG_AUDIT_PROMPT=1."""
    if os.environ.get("NC_LOG_AUDIT_PROMPT") != "1":
        return
    print(f"=== {label} prompt (NC_LOG_AUDIT_PROMPT=1, {len(prompt)} bytes) ===",
          file=sys.stderr)
    print(prompt, file=sys.stderr)
    print(f"=== {label} prompt END ===", file=sys.stderr)


# =============================================================================
# Main commands
# =============================================================================

def _emit(v2: dict, method: str, model: str, cost_usd: float,
          input_tokens: int = 0, output_tokens: int = 0):
    """Write the final v2 JSON to stdout with metadata attached."""
    v2["method"] = method
    v2["model"] = model
    v2["cost_usd"] = cost_usd
    v2["input_tokens"] = input_tokens
    v2["output_tokens"] = output_tokens
    print(json.dumps(v2))


def audit_plan(plan_file: str, task_file: str, rules_file: str,
               project_path: str = None, *,
               task_id: str = None, session_dir: str = None):
    """Audit a mini-plan. Tries Codex CLI exec first, falls back to API."""
    plan = Path(plan_file).read_text()
    task = Path(task_file).read_text()
    rules = Path(rules_file).read_text() if Path(rules_file).exists() else "No project rules provided."
    persona = _load_audit_persona(project_path)

    # F1: relevance pack replaces _read_project_context when flag is on.
    pack_text, pack_meta_path = _maybe_build_pack(
        project_path=project_path,
        task_text=task,
        task_id=task_id,
        phase="plan_audit",
        session_dir=session_dir,
    )
    if pack_text is not None:
        context_section = f"""PROJECT RULES:
{rules}

{pack_text}"""
        if pack_meta_path:
            print(f"relevance_pack: meta sidecar at {pack_meta_path}", file=sys.stderr)
    else:
        project_context = _read_project_context(project_path)
        context_section = f"""TASK REQUIREMENTS:
{task}

PROJECT RULES:
{rules}

PROJECT CONTEXT (spec, progress, existing code — use these to validate the plan):
{project_context}"""

    audit_prompt = f"""{persona}

{context_section}

MINI-PLAN TO AUDIT:
{plan}

{_schema_instructions()}"""
    _maybe_log_prompt("audit_plan", audit_prompt)

    # Try CLI first
    if codex_cli_available():
        result = codex_cli_exec(audit_prompt, project_path)
        if result.get("content") and not result.get("error"):
            v2 = parse_structured_verdict(result["content"])
            _emit(v2, method="cli", model=result["model"], cost_usd=0.0)
            return

        print(f"CLI failed ({result.get('error', 'unknown')}), falling back to API", file=sys.stderr)

    # Fallback to API
    system_prompt = f"""{persona}

YOUR ROLE:
- You audit implementation plans created by another AI model.
- The goal is fast iteration — sufficient quality; humans handle polish.

{_schema_instructions()}"""

    user_prompt = f"""Audit this mini-plan against the task requirements and project rules.

{context_section}

MINI-PLAN TO AUDIT:
{plan}

Return the v2 JSON object described above."""
    _maybe_log_prompt("audit_plan (API fallback)", user_prompt)

    result = call_api(system_prompt, user_prompt)
    v2 = parse_structured_verdict(result["content"])
    _emit(
        v2,
        method=result["method"],
        model=result["model"],
        cost_usd=result["cost_usd"],
        input_tokens=result.get("input_tokens", 0),
        output_tokens=result.get("output_tokens", 0),
    )


def review_impl(project_path: str, plan_file: str, rules_file: str, base_branch: str = None,
                diff_source: str = None, test_output_file: str = None, *,
                task_id: str = None, session_dir: str = None,
                changed_files: list = None):
    """Review implementation. Tries codex exec CLI first, falls back to API."""
    plan = Path(plan_file).read_text()
    rules = Path(rules_file).read_text() if Path(rules_file).exists() else "No project rules provided."
    persona = _load_audit_persona(project_path)

    # Get diff for both CLI and API paths. `git diff` / `git diff --staged`
    # don't include untracked files, so we synthesize added-file diffs for any
    # new modules the implementer created — otherwise the reviewer never sees
    # their content.
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

        # Append synthesized added-file diffs for untracked files.
        try:
            untracked = subprocess.run(
                ["git", "ls-files", "--others", "--exclude-standard"],
                capture_output=True, text=True, cwd=project_path, timeout=5,
            ).stdout.splitlines()
        except (FileNotFoundError, subprocess.TimeoutExpired):
            untracked = []
        for rel in (u.strip() for u in untracked):
            if not rel:
                continue
            fpath = Path(project_path) / rel
            try:
                if fpath.is_file():
                    body = fpath.read_text(errors="replace")
                else:
                    continue
            except OSError:
                continue
            # Cap per-file body to avoid blowing the diff budget on one huge file.
            if len(body) > 20000:
                body = body[:20000] + "\n... [untracked file body truncated]\n"
            synth = [
                f"diff --git a/{rel} b/{rel}",
                "new file mode 100644",
                "--- /dev/null",
                f"+++ b/{rel}",
            ]
            for line in body.splitlines():
                synth.append("+" + line)
            diff = (diff or "") + "\n" + "\n".join(synth) + "\n"

    if len(diff) > 80000:
        diff = diff[:40000] + "\n\n... [TRUNCATED] ...\n\n" + diff[-40000:]

    test_output = ""
    if test_output_file and os.path.isfile(test_output_file):
        test_output = Path(test_output_file).read_text()

    # F1: derive changed files from git if not passed explicitly.
    # Only needed when relevance pack is on (cheap guard — skip the git call otherwise).
    # Includes untracked files — symmetric with the diff-body synthesis above.
    if changed_files is None and os.environ.get("NC_RELEVANCE_PACK") == "1":
        changed_files = []
        for args in (["git", "diff", "--name-only"],
                     ["git", "diff", "--staged", "--name-only"],
                     ["git", "ls-files", "--others", "--exclude-standard"]):
            try:
                rg = subprocess.run(args, capture_output=True, text=True,
                                    cwd=project_path, timeout=5)
                for ln in rg.stdout.splitlines():
                    ln = ln.strip()
                    if ln and ln not in changed_files:
                        changed_files.append(ln)
            except (FileNotFoundError, subprocess.TimeoutExpired):
                pass

    pack_text, pack_meta_path = _maybe_build_pack(
        project_path=project_path,
        task_text=plan,  # review phase: the plan is the closest thing to "task text"
        task_id=task_id,
        phase="impl_review",
        session_dir=session_dir,
        changed_files=changed_files,
    )
    if pack_text is not None and pack_meta_path:
        print(f"relevance_pack: meta sidecar at {pack_meta_path}", file=sys.stderr)

    pack_block = f"\n\n{pack_text}\n" if pack_text else ""

    review_prompt = f"""{persona}

APPROVED PLAN:
{plan[:3000]}

KEY RULES:
{rules[:2000]}
{pack_block}
GIT DIFF:
```diff
{diff[:30000]}
```

TEST OUTPUT:
```
{test_output[:5000]}
```

YOUR ROLE:
- You review implementations created by another AI model against the approved plan.
- Reject only for real bugs, security issues, or deviations that affect correctness.

{_schema_instructions()}"""
    _maybe_log_prompt("review_impl", review_prompt)

    # Try CLI first
    if codex_cli_available():
        result = codex_cli_exec(review_prompt, project_path)
        if result.get("content") and not result.get("error"):
            v2 = parse_structured_verdict(result["content"])
            _emit(v2, method="cli", model=result["model"], cost_usd=0.0)
            return

        print(f"CLI failed ({result.get('error', 'unknown')}), falling back to API", file=sys.stderr)

    # Fallback to API
    system_prompt = f"""{persona}

YOUR ROLE:
- You review implementations created by another AI model against the approved plan.
- The goal is fast iteration — sufficient quality; humans handle polish.

{_schema_instructions()}"""

    user_prompt = f"""Review this implementation against the approved plan and project rules.

APPROVED PLAN:
{plan}

PROJECT RULES:
{rules}
{pack_block}
GIT DIFF (changes made):
```diff
{diff}
```

TEST OUTPUT:
```
{test_output}
```

Return the v2 JSON object described above."""
    _maybe_log_prompt("review_impl (API fallback)", user_prompt)

    result = call_api(system_prompt, user_prompt)
    v2 = parse_structured_verdict(result["content"])
    _emit(
        v2,
        method=result["method"],
        model=result["model"],
        cost_usd=result["cost_usd"],
        input_tokens=result.get("input_tokens", 0),
        output_tokens=result.get("output_tokens", 0),
    )


def parse_test():
    """Read content from stdin and emit the parsed v2 JSON. No LLM call.

    Lets test harnesses exercise parse_structured_verdict without any network.
    """
    content = sys.stdin.read()
    v2 = parse_structured_verdict(content)
    _emit(v2, method="test", model="parse-test", cost_usd=0.0)


def test_connectivity():
    """Test Codex CLI and API connectivity."""
    results = {}

    if codex_cli_available():
        cli_result = codex_cli_exec("Reply with exactly: CODEX_CLI_OK")
        if cli_result.get("content") and not cli_result.get("error"):
            results["cli"] = {"status": "ok", "model": "gpt-5.4", "response": cli_result["content"][:100]}
        else:
            results["cli"] = {"status": "error", "error": cli_result.get("error", "empty output")}
    else:
        results["cli"] = {"status": "not_installed"}

    try:
        api_result = call_api(
            "You are a test assistant.",
            "Reply with exactly: CODEX_API_OK",
            max_tokens=10,
        )
        results["api"] = {"status": "ok", "model": API_MODEL, "cost_usd": api_result["cost_usd"]}
    except Exception as e:
        results["api"] = {"status": "error", "error": str(e)}

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
    parser.add_argument("--parse-test", action="store_true", dest="parse_test",
                        help="Read content from stdin, emit parsed v2 JSON (no LLM call)")
    parser.add_argument("--plan")
    parser.add_argument("--task-file")
    parser.add_argument("--rules")
    parser.add_argument("--project")
    parser.add_argument("--diff")
    parser.add_argument("--test-output")
    parser.add_argument("--base")
    # F1 plumbing — required when NC_RELEVANCE_PACK=1; harmless otherwise.
    parser.add_argument("--task-id", dest="task_id", default=None,
                        help="Task ID (e.g. NC-042) — used as relevance pack key")
    parser.add_argument("--session-dir", dest="session_dir", default=None,
                        help="Nightcrawler SESSION_DIR — relevance packs & prior-findings scan root")
    parser.add_argument("--changed-files", dest="changed_files", default=None,
                        help="Comma-separated list of changed files (review phase only). "
                             "If omitted, derived from `git diff --name-only`.")

    args = parser.parse_args()

    changed_files_list = None
    if args.changed_files:
        changed_files_list = [f for f in (s.strip() for s in args.changed_files.split(","))
                              if f]

    if args.test:
        test_connectivity()
    elif args.parse_test:
        parse_test()
    elif args.command == "audit-plan":
        audit_plan(
            args.plan, args.task_file, args.rules, args.project,
            task_id=args.task_id, session_dir=args.session_dir,
        )
    elif args.command == "review-impl":
        review_impl(
            args.project, args.plan, args.rules, args.base, args.diff, args.test_output,
            task_id=args.task_id, session_dir=args.session_dir,
            changed_files=changed_files_list,
        )
    else:
        parser.print_help()
        sys.exit(1)
