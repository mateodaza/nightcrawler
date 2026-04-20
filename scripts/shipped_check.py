#!/usr/bin/env python3
"""
shipped_check.py — F5 companion-side existence check (Codex CLI primary, API fallback).

Runs BEFORE the planner to decide whether a backlog task's functional intent
is already satisfied by code on the active branch. The orchestrator uses the
verdict to skip, re-scope, or proceed normally.

Usage:
    shipped_check.py check --task-id <id> --task-file <path> --project <path> \\
        [--session-dir <path>]
    shipped_check.py --parse-test   (read response from stdin, emit parsed JSON; no LLM)
    shipped_check.py --test         (validate Codex CLI or API connectivity; delegates
                                     to call_codex.test_connectivity)

Output (v1 contract, schema_version: 1):
    {
        "schema_version": 1,
        "verdict": "SHIPPED" | "PARTIAL" | "NOT_SHIPPED" | "UNCERTAIN",
        "confidence": "high" | "medium" | "low" | "unknown",
        "summary": "...",
        "evidence": [{"type": "file" | "commit", "ref": "...", "excerpt": "..."}],
        "open_questions": ["..."],

        // Coercion telemetry (only present when fired):
        "contract_violations": [
            "unparseable"
            | "invalid_verdict_coerced"
            | "shipped_without_evidence_coerced"
            | "shipped_low_confidence_coerced"
        ],

        // Metadata:
        "method": "cli" | "api" | "test",
        "model": "...",
        "cost_usd": ...,
        "input_tokens": ..., "output_tokens": ...
    }

Design notes:
- Reuses the F1 relevance-pack builder with `phase="shipped_check"` (task spec
  + likely files + per-file git history, no prior-findings or audit-patterns).
- The prompt body lives in scripts/prompts/shipped_check.md so it can be edited
  without code changes. If the file is missing, an inline fallback is used and
  a warning is printed to stderr (the orchestrator should not crash just
  because the prompt file was deleted).
- Safety coercions bias toward UNCERTAIN — a false SHIPPED skips the task
  outright, a false NOT_SHIPPED only costs one planner round. SHIPPED requires
  confidence="high" AND non-empty evidence[]; violations are coerced to
  UNCERTAIN with a contract_violations tag.
"""

import argparse
import json
import os
import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import call_codex  # noqa: E402

SCHEMA_VERSION = 1
PROMPT_PATH = SCRIPTS_DIR / "prompts" / "shipped_check.md"

_VERDICTS = {"SHIPPED", "PARTIAL", "NOT_SHIPPED", "UNCERTAIN"}
_CONFIDENCES = {"high", "medium", "low", "unknown"}

_INLINE_FALLBACK_PROMPT = """You are the Nightcrawler shipped-task checker.

Decide whether this task's functional intent is already present in the code
shown below. Four possible verdicts: SHIPPED / PARTIAL / NOT_SHIPPED / UNCERTAIN.
Prefer UNCERTAIN over guessing when evidence is ambiguous.

SHIPPED requires at least one evidence[] entry (file:line or commit SHA) AND
confidence="high" — a false SHIPPED loses work; a false NOT_SHIPPED only costs
one planner round.
"""


def _load_prompt_body() -> str:
    """Read scripts/prompts/shipped_check.md; fall back to an inline stub."""
    if PROMPT_PATH.exists():
        try:
            return PROMPT_PATH.read_text()
        except OSError as exc:
            print(f"shipped_check: prompt read failed ({exc}); using inline fallback",
                  file=sys.stderr)
    else:
        print(f"shipped_check: {PROMPT_PATH} missing; using inline fallback",
              file=sys.stderr)
    return _INLINE_FALLBACK_PROMPT


def _schema_instructions() -> str:
    """JSON contract instructions appended to every prompt."""
    return f"""
RESPONSE FORMAT — return a single JSON object and NOTHING ELSE. No prose, no
markdown fences, no preamble.

{{
  "verdict": "SHIPPED" | "PARTIAL" | "NOT_SHIPPED" | "UNCERTAIN",
  "confidence": "high" | "medium" | "low",
  "summary": "one or two sentences — what you observed",
  "evidence": [
    {{"type": "file" | "commit",
      "ref": "path/to/file:42  OR  <commit-sha>",
      "excerpt": "the specific line or commit subject that grounds this point"}}
  ],
  "open_questions": ["specific checks the planner should verify"],
  "schema_version": {SCHEMA_VERSION}
}}

RULES:
- SHIPPED: every acceptance criterion is satisfied by existing code.
  Requires ≥1 evidence[] entry AND confidence="high". Otherwise use UNCERTAIN.
- PARTIAL: some AC present, others absent. Use open_questions[] to list what
  still needs to be done so the planner can re-scope.
- NOT_SHIPPED: nothing in the pack satisfies the task.
- UNCERTAIN: evidence ambiguous, pack thin, or task underspecified. PREFER
  UNCERTAIN OVER GUESSING.
- Never include prose outside the JSON object.
""".strip()


def _empty() -> dict:
    """Shape of an empty-but-valid v1 response (default = UNCERTAIN)."""
    return {
        "schema_version": SCHEMA_VERSION,
        "verdict": "UNCERTAIN",
        "confidence": "unknown",
        "summary": "",
        "evidence": [],
        "open_questions": [],
    }


def parse_shipped_verdict(content: str) -> dict:
    """Parse a shipped_check response into the v1 contract shape.

    Coercion rules (safety net — prompt already instructs the model):
    - Unparseable → UNCERTAIN, contract_violations includes "unparseable".
    - Invalid/missing verdict → UNCERTAIN, "invalid_verdict_coerced".
    - SHIPPED with empty evidence[] → UNCERTAIN, "shipped_without_evidence_coerced".
    - SHIPPED with confidence != "high" → UNCERTAIN, "shipped_low_confidence_coerced".

    Always returns a dict with all v1 fields populated.
    """
    obj = call_codex._extract_json_object(content or "")
    violations: list = []

    if obj is None or not isinstance(obj, dict):
        out = _empty()
        raw = (content or "").strip()
        if raw:
            out["summary"] = raw[:500]
        violations.append("unparseable")
        out["contract_violations"] = violations
        return out

    out = _empty()

    # verdict
    verdict_raw = str(obj.get("verdict", "")).upper().strip()
    if verdict_raw not in _VERDICTS:
        out["verdict"] = "UNCERTAIN"
        violations.append("invalid_verdict_coerced")
    else:
        out["verdict"] = verdict_raw

    # confidence
    confidence = str(obj.get("confidence", "unknown")).lower().strip()
    if confidence not in _CONFIDENCES:
        confidence = "unknown"
    out["confidence"] = confidence

    # summary
    summary = obj.get("summary")
    out["summary"] = str(summary) if summary is not None else ""

    # evidence — keep only dict entries
    ev = obj.get("evidence")
    if isinstance(ev, list):
        out["evidence"] = [e for e in ev if isinstance(e, dict)]
    else:
        out["evidence"] = []

    # open_questions — keep only string-coercible entries
    oq = obj.get("open_questions")
    if isinstance(oq, list):
        out["open_questions"] = [
            str(q) for q in oq if isinstance(q, (str, int, float))
        ]
    else:
        out["open_questions"] = []

    # schema_version
    try:
        out["schema_version"] = int(obj.get("schema_version", SCHEMA_VERSION)
                                    or SCHEMA_VERSION)
    except (TypeError, ValueError):
        out["schema_version"] = SCHEMA_VERSION

    # Safety coercions: SHIPPED is the aggressive path (skip the task).
    # Require both high confidence AND non-empty evidence. Any gap → UNCERTAIN.
    if out["verdict"] == "SHIPPED":
        if not out["evidence"]:
            out["verdict"] = "UNCERTAIN"
            violations.append("shipped_without_evidence_coerced")
        elif out["confidence"] != "high":
            out["verdict"] = "UNCERTAIN"
            violations.append("shipped_low_confidence_coerced")

    if violations:
        out["contract_violations"] = violations
    return out


def _build_shipped_pack(task_text: str, task_id: str, project_path: str,
                        session_dir: str = None) -> dict:
    """Assemble the F1 relevance pack in shipped_check mode. Returns the dict
    from relevance_pack.build_pack (keys: text, meta, artifacts)."""
    lib_dir = SCRIPTS_DIR
    if str(lib_dir) not in sys.path:
        sys.path.insert(0, str(lib_dir))
    from lib import relevance_pack  # type: ignore

    artifact_dir = None
    state_dir = os.environ.get("NIGHTCRAWLER_STATE_PATH")
    if session_dir:
        artifact_dir = str(Path(session_dir) / "relevance-packs")
        if not state_dir:
            try:
                state_dir = str(Path(session_dir).resolve().parent.parent)
            except OSError:
                state_dir = None

    return relevance_pack.build_pack(
        task_text=task_text,
        task_id=task_id or "unknown",
        phase="shipped_check",
        project_path=project_path or ".",
        state_dir=state_dir,
        artifact_dir=artifact_dir,
        current_session_dir=session_dir,
    )


def _emit(parsed: dict, *, method: str, model: str,
          cost_usd: float, input_tokens: int = 0,
          output_tokens: int = 0) -> None:
    """Write the final JSON to stdout with metadata attached."""
    parsed["method"] = method
    parsed["model"] = model
    parsed["cost_usd"] = cost_usd
    parsed["input_tokens"] = input_tokens
    parsed["output_tokens"] = output_tokens
    print(json.dumps(parsed))


def _maybe_log_prompt(prompt: str) -> None:
    """Dump the assembled shipped_check prompt to stderr when NC_LOG_SHIPPED_PROMPT=1.
    Mirrors the NC_LOG_AUDIT_PROMPT pattern from call_codex."""
    if os.environ.get("NC_LOG_SHIPPED_PROMPT") != "1":
        return
    print(f"=== shipped_check prompt (NC_LOG_SHIPPED_PROMPT=1, {len(prompt)} bytes) ===",
          file=sys.stderr)
    print(prompt, file=sys.stderr)
    print("=== shipped_check prompt END ===", file=sys.stderr)


def run_check(task_id: str, task_file: str, project_path: str,
              session_dir: str = None) -> None:
    """Run the shipped_check against a single task. Emits parsed JSON to stdout."""
    task_text = Path(task_file).read_text()

    try:
        pack = _build_shipped_pack(task_text, task_id, project_path, session_dir)
    except Exception as exc:  # defensive — never let the pack break the check
        print(f"shipped_check: pack build failed ({exc}); emitting UNCERTAIN",
              file=sys.stderr)
        out = _empty()
        out["contract_violations"] = ["pack_build_failed"]
        out["summary"] = f"pack build failed: {exc}"
        _emit(out, method="test", model="pack-failure", cost_usd=0.0)
        return

    pack_meta_path = pack["artifacts"].get("meta_path")
    if pack_meta_path:
        print(f"shipped_check pack meta: {pack_meta_path}", file=sys.stderr)

    prompt_body = _load_prompt_body()
    prompt = f"""{prompt_body}

{pack["text"]}

{_schema_instructions()}"""
    _maybe_log_prompt(prompt)

    # Try Codex CLI first (gpt-5.4), same as the auditor pipeline.
    if call_codex.codex_cli_available():
        cli_result = call_codex.codex_cli_exec(prompt, project_path)
        if cli_result.get("content") and not cli_result.get("error"):
            parsed = parse_shipped_verdict(cli_result["content"])
            _emit(parsed, method="cli", model=cli_result.get("model", "gpt-5.4"),
                  cost_usd=0.0)
            return
        print(f"shipped_check: CLI failed ({cli_result.get('error', 'unknown')}); "
              "falling back to API", file=sys.stderr)

    # API fallback.
    system_prompt = (
        "You are the Nightcrawler shipped-task checker. Decide whether a task's "
        "functional intent is already present in the code shown in the user "
        "message. Return a single JSON object per the schema — no prose.\n\n"
        + _schema_instructions()
    )
    try:
        api_result = call_codex.call_api(system_prompt, prompt)
    except Exception as exc:
        print(f"shipped_check: API call failed ({exc}); emitting UNCERTAIN",
              file=sys.stderr)
        out = _empty()
        out["contract_violations"] = ["api_call_failed"]
        out["summary"] = f"API call failed: {exc}"
        _emit(out, method="test", model="api-failure", cost_usd=0.0)
        return

    parsed = parse_shipped_verdict(api_result["content"])
    _emit(
        parsed,
        method=api_result["method"],
        model=api_result["model"],
        cost_usd=api_result["cost_usd"],
        input_tokens=api_result.get("input_tokens", 0),
        output_tokens=api_result.get("output_tokens", 0),
    )


def parse_test() -> None:
    """Read a response from stdin, emit parsed v1 JSON. No LLM call."""
    content = sys.stdin.read()
    parsed = parse_shipped_verdict(content)
    _emit(parsed, method="test", model="parse-test", cost_usd=0.0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="F5 shipped-task check (Nightcrawler companion)"
    )
    parser.add_argument("command", nargs="?", choices=["check"], default=None)
    parser.add_argument("--parse-test", action="store_true", dest="parse_test",
                        help="Read a response body from stdin and emit parsed "
                             "v1 JSON (no LLM call)")
    parser.add_argument("--test", action="store_true",
                        help="Validate Codex CLI/API connectivity "
                             "(delegates to call_codex.test_connectivity)")
    parser.add_argument("--task-id", dest="task_id", default=None)
    parser.add_argument("--task-file", dest="task_file", default=None)
    parser.add_argument("--project", dest="project", default=None)
    parser.add_argument("--session-dir", dest="session_dir", default=None)

    args = parser.parse_args()

    if args.parse_test:
        parse_test()
    elif args.test:
        call_codex.test_connectivity()
    elif args.command == "check":
        if not (args.task_id and args.task_file and args.project):
            parser.error("check requires --task-id, --task-file, --project")
        run_check(args.task_id, args.task_file, args.project, args.session_dir)
    else:
        parser.print_help()
        sys.exit(1)
