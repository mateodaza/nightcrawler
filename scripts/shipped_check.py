#!/usr/bin/env python3
"""
shipped_check.py — F5 companion-side existence check (parser + prompt emitter).

This module has two responsibilities and nothing else:

1. `build-prompt` subcommand — assemble the F1 relevance pack in
   phase="shipped_check" mode, combine it with the persona prompt and the v1
   JSON schema instructions, and emit the full prompt body to stdout. The
   bash orchestrator owns the actual LLM call (see nightcrawler.sh F5.3 wiring
   — `call_claude 60 "$prompt" --model sonnet --output-format json --max-turns 1`).

2. `parse_shipped_verdict(content) / --parse-test` — normalize a model response
   into the v1 contract shape with conservative coercion rules. SHIPPED is the
   aggressive verdict (it makes the orchestrator SKIP the task entirely), so
   the parser biases hard toward UNCERTAIN: SHIPPED without evidence or with
   less-than-high confidence is downgraded with a `contract_violations` tag.

Usage:
    shipped_check.py build-prompt --task-id <id> --task-file <path> \\
        --project <path> [--session-dir <path>]
    shipped_check.py inject-partial --task-file <path> --verdict-json <path>
    shipped_check.py --parse-test   (read response from stdin, emit parsed JSON)

Why parser + emitter (not orchestrator):
The previous shape of this file invoked `call_codex.codex_cli_exec` / `call_api`
directly. That exercised a different model, budget, and failure surface than
the F5 plan and cost assumptions were built around. The orchestrator (bash)
now drives the call via the same `call_claude` path as every other Claude
hop, keeping budget, retry, streaming, and cost accounting unified. This
file stays pure: no network, no subprocess, no env assumptions beyond the
pack builder's own.

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

        // Metadata stamped by --parse-test:
        "method": "parse-test",
        "model": "parse-test",
        "cost_usd": 0.0,
        "input_tokens": 0, "output_tokens": 0
    }
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

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


# ---------------------------------------------------------------------------
# JSON extraction — inlined from call_codex so this module stays
# self-contained. Kept byte-identical to the call_codex version so any bug
# fixes there should be mirrored here (and vice versa); divergence would
# cause parse_shipped_verdict and the auditor to disagree on the same input.
# ---------------------------------------------------------------------------

_JSON_OBJECT_RE = re.compile(r"\{[\s\S]*\}")


def _extract_json_object(content: str):
    """Return the first parseable JSON object in content, or None.

    Handles responses that wrap JSON in ```json ... ``` fences or in prose.
    Strategy: strip fences, then try progressively larger candidate slices
    starting at the first '{' and working outward.
    """
    if not content:
        return None

    stripped = content.strip()
    if stripped.startswith("```"):
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
    while candidate:
        try:
            obj = json.loads(candidate)
            if isinstance(obj, dict):
                return obj
        except Exception:
            pass
        candidate = candidate[:-1]
        if len(candidate) < 2:
            return None
    return None


# ---------------------------------------------------------------------------
# Prompt assembly
# ---------------------------------------------------------------------------

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


def assemble_prompt(task_text: str, task_id: str, project_path: str,
                    session_dir: str = None) -> str:
    """Combine persona + pack + schema into a single prompt body. Pure string
    assembly — no LLM call. The bash orchestrator owns the call."""
    pack = _build_shipped_pack(task_text, task_id, project_path, session_dir)
    pack_meta_path = pack["artifacts"].get("meta_path")
    if pack_meta_path:
        print(f"shipped_check pack meta: {pack_meta_path}", file=sys.stderr)

    prompt_body = _load_prompt_body()
    return f"""{prompt_body}

{pack["text"]}

{_schema_instructions()}"""


# ---------------------------------------------------------------------------
# Parser — the invariant piece. Everything above is prompt shaping; this is
# the contract F5.3 depends on for verdict normalization.
# ---------------------------------------------------------------------------

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
    obj = _extract_json_object(content or "")
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


# ---------------------------------------------------------------------------
# PARTIAL injection — rewrite task_context.md with a preamble block when the
# shipped_check returns PARTIAL. The original spec is snapshotted to
# task_context.original.md on first call and left alone on subsequent calls
# (so retries / resume don't clobber the first-seen spec).
# ---------------------------------------------------------------------------

_PARTIAL_INSTRUCTION = (
    "Planner and auditor: extend existing work; already-satisfied ACs are "
    "'shipped — verify only'."
)


def format_partial_block(verdict_obj: dict) -> str:
    """Return the PARTIAL preamble block (no trailing original spec).

    Shape:
        ## Shipped-task check: <VERDICT>

        **Summary:** <one or two sentences>

        **Evidence:**
        - (file) `path:line` — excerpt
        - (commit) `sha` — subject

        **Open questions:**
        - q1
        - q2

        Planner and auditor: extend existing work; already-satisfied ACs are
        'shipped — verify only'.

        ---

    Empty evidence[] / open_questions[] sections are omitted entirely rather
    than rendered as empty headers, so the block stays readable when the
    model returns a sparse verdict.
    """
    verdict = str(verdict_obj.get("verdict", "UNCERTAIN") or "UNCERTAIN")
    summary = str(verdict_obj.get("summary", "") or "").strip()
    evidence = verdict_obj.get("evidence") or []
    open_questions = verdict_obj.get("open_questions") or []

    lines: list = []
    lines.append(f"## Shipped-task check: {verdict}")
    lines.append("")

    if summary:
        lines.append(f"**Summary:** {summary}")
        lines.append("")

    if isinstance(evidence, list) and evidence:
        rendered: list = []
        for e in evidence:
            if not isinstance(e, dict):
                continue
            etype = str(e.get("type", "") or "").strip()
            ref = str(e.get("ref", "") or "").strip()
            excerpt = str(e.get("excerpt", "") or "").strip()
            parts: list = []
            if etype:
                parts.append(f"({etype})")
            if ref:
                parts.append(f"`{ref}`")
            if excerpt:
                parts.append(f"— {excerpt}")
            if parts:
                rendered.append("- " + " ".join(parts))
        if rendered:
            lines.append("**Evidence:**")
            lines.extend(rendered)
            lines.append("")

    if isinstance(open_questions, list) and open_questions:
        rendered_q: list = []
        for q in open_questions:
            q_str = str(q).strip()
            if q_str:
                rendered_q.append(f"- {q_str}")
        if rendered_q:
            lines.append("**Open questions:**")
            lines.extend(rendered_q)
            lines.append("")

    lines.append(_PARTIAL_INSTRUCTION)
    lines.append("")
    lines.append("---")
    lines.append("")

    return "\n".join(lines)


def _original_snapshot_path(task_file: Path) -> Path:
    """task_context.md → task_context.original.md (stem + '.original' + suffix)."""
    suffix = task_file.suffix or ".md"
    stem = task_file.stem or "task"
    return task_file.with_name(f"{stem}.original{suffix}")


def inject_partial_cli(task_file: str, verdict_json: str) -> None:
    """Read verdict_json, snapshot task_file → <stem>.original<suffix> (only
    if absent), and rewrite task_file with the PARTIAL block prepended to the
    original spec.

    Idempotency contract (matches feedback: "preserve original only once"):
    - First call: copies current task_file → .original.md, writes block + original.
    - Subsequent calls: reads from .original.md (ignoring whatever's currently
      in task_file), rewrites task_file with fresh block + original. The
      .original.md snapshot is never overwritten.
    """
    task_path = Path(task_file)
    if not task_path.exists():
        print(f"shipped_check: task file {task_file} not found",
              file=sys.stderr)
        sys.exit(2)

    try:
        verdict_obj = json.loads(Path(verdict_json).read_text())
    except (OSError, ValueError) as exc:
        print(f"shipped_check: cannot read verdict JSON {verdict_json}: {exc}",
              file=sys.stderr)
        sys.exit(2)

    original_path = _original_snapshot_path(task_path)

    if not original_path.exists():
        try:
            original_text = task_path.read_text()
            original_path.write_text(original_text)
        except OSError as exc:
            print(f"shipped_check: cannot snapshot original task file: {exc}",
                  file=sys.stderr)
            sys.exit(3)
    else:
        try:
            original_text = original_path.read_text()
        except OSError as exc:
            print(f"shipped_check: cannot read original snapshot "
                  f"{original_path}: {exc}", file=sys.stderr)
            sys.exit(3)

    block = format_partial_block(verdict_obj)
    try:
        task_path.write_text(block + original_text)
    except OSError as exc:
        print(f"shipped_check: cannot write augmented task file "
              f"{task_path}: {exc}", file=sys.stderr)
        sys.exit(3)


# ---------------------------------------------------------------------------
# CLI entry points
# ---------------------------------------------------------------------------

def _emit_parse_result(parsed: dict) -> None:
    """Stamp parse-test metadata and print one JSON line. Kept in sync with
    the bash wrapper's expectations — the call_claude layer supplies its own
    method/model/cost metadata when it invokes the parser."""
    parsed["method"] = "parse-test"
    parsed["model"] = "parse-test"
    parsed["cost_usd"] = 0.0
    parsed["input_tokens"] = 0
    parsed["output_tokens"] = 0
    print(json.dumps(parsed))


def build_prompt_cli(task_id: str, task_file: str, project_path: str,
                     session_dir: str = None) -> None:
    """Assemble the prompt and write it to stdout for the bash caller."""
    try:
        task_text = Path(task_file).read_text()
    except OSError as exc:
        print(f"shipped_check: cannot read task file {task_file}: {exc}",
              file=sys.stderr)
        sys.exit(2)

    try:
        prompt = assemble_prompt(task_text, task_id, project_path, session_dir)
    except Exception as exc:  # defensive — nightcrawler.sh treats non-zero as skip-check
        print(f"shipped_check: prompt assembly failed ({exc})", file=sys.stderr)
        sys.exit(3)

    sys.stdout.write(prompt)
    if not prompt.endswith("\n"):
        sys.stdout.write("\n")


def parse_test() -> None:
    """Read a response from stdin, emit parsed v1 JSON. No LLM call."""
    content = sys.stdin.read()
    parsed = parse_shipped_verdict(content)
    _emit_parse_result(parsed)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="F5 shipped-task check — parser + prompt emitter "
                    "(the bash orchestrator owns the LLM call)"
    )
    parser.add_argument("command", nargs="?",
                        choices=["build-prompt", "inject-partial"],
                        default=None,
                        help="build-prompt: assemble persona + pack + schema "
                             "and emit to stdout. "
                             "inject-partial: rewrite --task-file with the "
                             "PARTIAL preamble from --verdict-json (snapshots "
                             "original to <stem>.original<suffix> once).")
    parser.add_argument("--parse-test", action="store_true", dest="parse_test",
                        help="Read a response body from stdin and emit parsed "
                             "v1 JSON (no LLM call)")
    parser.add_argument("--task-id", dest="task_id", default=None)
    parser.add_argument("--task-file", dest="task_file", default=None)
    parser.add_argument("--project", dest="project", default=None)
    parser.add_argument("--session-dir", dest="session_dir", default=None)
    parser.add_argument("--verdict-json", dest="verdict_json", default=None,
                        help="Path to parsed shipped_check verdict JSON "
                             "(inject-partial only)")

    args = parser.parse_args()

    if args.parse_test:
        parse_test()
    elif args.command == "build-prompt":
        if not (args.task_id and args.task_file and args.project):
            parser.error("build-prompt requires --task-id, --task-file, --project")
        build_prompt_cli(args.task_id, args.task_file, args.project,
                         args.session_dir)
    elif args.command == "inject-partial":
        if not (args.task_file and args.verdict_json):
            parser.error("inject-partial requires --task-file and --verdict-json")
        inject_partial_cli(args.task_file, args.verdict_json)
    else:
        parser.print_help()
        sys.exit(1)
