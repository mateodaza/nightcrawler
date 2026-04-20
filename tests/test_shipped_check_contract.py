#!/usr/bin/env python3
"""F5 contract tests — shipped_check.parse_shipped_verdict behavior.

Runs standalone (no pytest required). Exit code: 0 = all pass, 1 = any fail.

Run with:
    python3 tests/test_shipped_check_contract.py
"""

import json
import sys
from pathlib import Path

# Make scripts/ importable without polluting PYTHONPATH globally.
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import shipped_check  # noqa: E402


_FAIL = []


def _check(label: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"  PASS  {label}")
    else:
        print(f"  FAIL  {label}" + (f" — {detail}" if detail else ""))
        _FAIL.append(label)


# ---------------------------------------------------------------------------
# Happy-path: each verdict preserves itself when the contract is satisfied.
# ---------------------------------------------------------------------------

def test_shipped_with_evidence_high_confidence_preserved() -> None:
    print("\n[test] SHIPPED + evidence + high confidence → preserved")
    src = json.dumps({
        "verdict": "SHIPPED",
        "confidence": "high",
        "summary": "all AC satisfied by existing handler",
        "evidence": [
            {"type": "file", "ref": "src/api/leads.ts:42",
             "excerpt": "if (!user.tenantId) throw 401"},
        ],
        "open_questions": [],
        "schema_version": 1,
    })
    out = shipped_check.parse_shipped_verdict(src)
    _check("verdict preserved", out["verdict"] == "SHIPPED")
    _check("evidence preserved", len(out["evidence"]) == 1,
           str(out["evidence"]))
    _check("no contract_violations", "contract_violations" not in out,
           str(out.get("contract_violations")))
    _check("schema_version=1", out["schema_version"] == 1)


def test_partial_preserved() -> None:
    print("\n[test] PARTIAL preserved with open_questions")
    src = json.dumps({
        "verdict": "PARTIAL",
        "confidence": "medium",
        "summary": "endpoint exists but missing auth check",
        "evidence": [
            {"type": "file", "ref": "src/api/leads.ts:10",
             "excerpt": "export async function GET(...)"},
        ],
        "open_questions": [
            "Does AC-3 require tenant isolation on the new endpoint?",
        ],
        "schema_version": 1,
    })
    out = shipped_check.parse_shipped_verdict(src)
    _check("verdict preserved", out["verdict"] == "PARTIAL")
    _check("open_questions preserved", len(out["open_questions"]) == 1)
    _check("no contract_violations", "contract_violations" not in out)


def test_not_shipped_passes_through() -> None:
    print("\n[test] NOT_SHIPPED with no evidence is fine")
    src = json.dumps({
        "verdict": "NOT_SHIPPED",
        "confidence": "high",
        "summary": "no handler for this endpoint in the pack",
        "evidence": [],
        "open_questions": [],
        "schema_version": 1,
    })
    out = shipped_check.parse_shipped_verdict(src)
    _check("verdict preserved", out["verdict"] == "NOT_SHIPPED")
    _check("no evidence required", out["evidence"] == [])
    _check("no contract_violations", "contract_violations" not in out)


def test_uncertain_preserved() -> None:
    print("\n[test] UNCERTAIN preserved regardless of evidence")
    src = json.dumps({
        "verdict": "UNCERTAIN",
        "confidence": "low",
        "summary": "pack did not include the decisive file",
        "evidence": [],
        "open_questions": ["Need to inspect src/auth/middleware.ts"],
        "schema_version": 1,
    })
    out = shipped_check.parse_shipped_verdict(src)
    _check("verdict preserved", out["verdict"] == "UNCERTAIN")
    _check("no contract_violations", "contract_violations" not in out)


# ---------------------------------------------------------------------------
# Coercions — SHIPPED is aggressive, so we bias hard toward UNCERTAIN.
# ---------------------------------------------------------------------------

def test_shipped_without_evidence_coerced() -> None:
    print("\n[test] SHIPPED with empty evidence[] → UNCERTAIN (coerced)")
    src = json.dumps({
        "verdict": "SHIPPED",
        "confidence": "high",
        "summary": "I believe this is done",
        "evidence": [],
        "open_questions": [],
        "schema_version": 1,
    })
    out = shipped_check.parse_shipped_verdict(src)
    _check("verdict coerced to UNCERTAIN", out["verdict"] == "UNCERTAIN",
           str(out.get("verdict")))
    _check("violation tag present",
           "shipped_without_evidence_coerced" in out.get("contract_violations", []),
           str(out.get("contract_violations")))


def test_shipped_with_low_confidence_coerced() -> None:
    print("\n[test] SHIPPED + confidence=medium → UNCERTAIN (coerced)")
    src = json.dumps({
        "verdict": "SHIPPED",
        "confidence": "medium",
        "summary": "looks done",
        "evidence": [{"type": "file", "ref": "src/a.ts:1", "excerpt": "..."}],
        "open_questions": [],
        "schema_version": 1,
    })
    out = shipped_check.parse_shipped_verdict(src)
    _check("verdict coerced to UNCERTAIN", out["verdict"] == "UNCERTAIN")
    _check("violation tag present",
           "shipped_low_confidence_coerced" in out.get("contract_violations", []),
           str(out.get("contract_violations")))
    # Evidence is still preserved so the notify layer can show what the model cited.
    _check("evidence preserved through coercion",
           len(out["evidence"]) == 1, str(out["evidence"]))


def test_invalid_verdict_coerced() -> None:
    print("\n[test] verdict='MAYBE' → UNCERTAIN (invalid_verdict_coerced)")
    src = json.dumps({
        "verdict": "MAYBE",
        "confidence": "high",
        "summary": "",
        "evidence": [],
        "open_questions": [],
        "schema_version": 1,
    })
    out = shipped_check.parse_shipped_verdict(src)
    _check("verdict coerced to UNCERTAIN", out["verdict"] == "UNCERTAIN")
    _check("violation tag present",
           "invalid_verdict_coerced" in out.get("contract_violations", []),
           str(out.get("contract_violations")))


def test_unparseable_falls_back_to_uncertain() -> None:
    print("\n[test] unparseable content → UNCERTAIN with 'unparseable' tag")
    out = shipped_check.parse_shipped_verdict("this is not json at all")
    _check("verdict=UNCERTAIN", out["verdict"] == "UNCERTAIN")
    _check("violation tag present",
           "unparseable" in out.get("contract_violations", []),
           str(out.get("contract_violations")))
    _check("summary captures the raw content",
           "not json" in out["summary"], str(out["summary"]))


def test_empty_input_falls_back_to_uncertain() -> None:
    print("\n[test] empty content → UNCERTAIN with 'unparseable' tag")
    out = shipped_check.parse_shipped_verdict("")
    _check("verdict=UNCERTAIN", out["verdict"] == "UNCERTAIN")
    _check("violation tag present",
           "unparseable" in out.get("contract_violations", []))


def test_fenced_json_extracted() -> None:
    """Model sometimes wraps JSON in ```json fences despite instructions."""
    print("\n[test] ```json-fenced response is extracted correctly")
    src = """```json
{
  "verdict": "NOT_SHIPPED",
  "confidence": "high",
  "summary": "clean",
  "evidence": [],
  "open_questions": [],
  "schema_version": 1
}
```"""
    out = shipped_check.parse_shipped_verdict(src)
    _check("verdict extracted from fence", out["verdict"] == "NOT_SHIPPED")
    _check("no contract_violations", "contract_violations" not in out)


def test_json_in_preamble_prose_extracted() -> None:
    print("\n[test] JSON embedded in prose is extracted")
    src = (
        "Here's my analysis:\n\n"
        '{"verdict": "NOT_SHIPPED", "confidence": "high", "summary": "ok", '
        '"evidence": [], "open_questions": [], "schema_version": 1}\n'
        "\nLet me know if you want me to look deeper."
    )
    out = shipped_check.parse_shipped_verdict(src)
    _check("verdict extracted from prose", out["verdict"] == "NOT_SHIPPED")


def test_missing_fields_filled_with_defaults() -> None:
    print("\n[test] partial JSON (only verdict) → all v1 fields populated with defaults")
    src = json.dumps({"verdict": "NOT_SHIPPED"})
    out = shipped_check.parse_shipped_verdict(src)
    _check("verdict preserved", out["verdict"] == "NOT_SHIPPED")
    _check("summary defaults to empty string", out["summary"] == "")
    _check("confidence defaults to 'unknown'", out["confidence"] == "unknown")
    _check("evidence defaults to []", out["evidence"] == [])
    _check("open_questions defaults to []", out["open_questions"] == [])
    _check("schema_version defaults to 1", out["schema_version"] == 1)


def test_malformed_evidence_list_sanitized() -> None:
    print("\n[test] evidence with non-dict entries → filtered, not crashed")
    src = json.dumps({
        "verdict": "PARTIAL",
        "confidence": "medium",
        "summary": "partial",
        "evidence": [
            {"type": "file", "ref": "src/a.ts:1", "excerpt": "valid"},
            "a stray string",
            42,
            None,
            {"type": "commit", "ref": "abc1234", "excerpt": "also valid"},
        ],
        "open_questions": [],
        "schema_version": 1,
    })
    out = shipped_check.parse_shipped_verdict(src)
    _check("only dict entries kept", len(out["evidence"]) == 2,
           str(out["evidence"]))
    _check("verdict preserved despite bad entries", out["verdict"] == "PARTIAL")


def test_unknown_confidence_normalised() -> None:
    print("\n[test] confidence='foo' → normalised to 'unknown'")
    src = json.dumps({
        "verdict": "NOT_SHIPPED",
        "confidence": "FOO",
        "summary": "",
        "evidence": [],
        "open_questions": [],
        "schema_version": 1,
    })
    out = shipped_check.parse_shipped_verdict(src)
    _check("confidence normalised to 'unknown'",
           out["confidence"] == "unknown", str(out["confidence"]))


def test_schema_version_non_int_falls_back() -> None:
    print("\n[test] schema_version='v1' (non-int) → falls back to 1")
    src = json.dumps({
        "verdict": "NOT_SHIPPED",
        "confidence": "high",
        "summary": "",
        "evidence": [],
        "open_questions": [],
        "schema_version": "v1",
    })
    out = shipped_check.parse_shipped_verdict(src)
    _check("schema_version=1 after fallback", out["schema_version"] == 1,
           str(out["schema_version"]))


# ---------------------------------------------------------------------------
# Architectural invariants — shipped_check.py is parser + prompt emitter.
# No LLM call path, no call_codex coupling. F5.3's nightcrawler.sh owns the
# model call via the shared call_claude helper.
# ---------------------------------------------------------------------------

def test_module_does_not_import_call_codex() -> None:
    """Regression for Codex audit P1 #1: the previous shape imported
    call_codex and invoked codex_cli_exec/call_api directly, which meant F5
    was silently running through the OpenAI auditor path instead of the
    planned Sonnet path. Keep the module free of that import so a refactor
    drift can't quietly reintroduce it."""
    print("\n[test] shipped_check does not import call_codex")
    src = Path(shipped_check.__file__).read_text()
    lines = src.splitlines()
    import_lines = [ln for ln in lines
                    if ln.strip().startswith(("import ", "from "))]
    _check("no 'import call_codex' in module source",
           not any("call_codex" in ln for ln in import_lines),
           str([ln for ln in import_lines if "call_codex" in ln]))
    _check("no run_check() orchestrator function",
           not hasattr(shipped_check, "run_check"),
           "found shipped_check.run_check — should live in bash, not python")


def test_build_prompt_emits_pack_persona_and_schema() -> None:
    """`build-prompt` must emit a prompt string containing: the persona
    block (from scripts/prompts/shipped_check.md or the inline fallback),
    the F1 relevance pack header, and the v1 JSON schema RESPONSE FORMAT
    instructions. The bash caller feeds this straight to `call_claude`."""
    import tempfile
    print("\n[test] assemble_prompt emits persona + pack + schema instructions")
    with tempfile.TemporaryDirectory() as tmp:
        proj = Path(tmp) / "proj"
        proj.mkdir()
        (proj / "src").mkdir()
        (proj / "src" / "a.ts").write_text("// BUILD_PROMPT_CANARY\n")
        task_file = proj / "task.md"
        task_file.write_text(
            "# NC-BP\n\n## Files\n- src/a.ts\n\n## AC\n- canary exists\n"
        )

        prompt = shipped_check.assemble_prompt(
            task_text=task_file.read_text(),
            task_id="NC-BP",
            project_path=str(proj),
            session_dir=None,
        )
        _check("prompt is non-trivial in size", len(prompt) > 500,
               f"{len(prompt)} bytes")
        _check("prompt includes shipped_check persona language",
               "shipped-task checker" in prompt.lower()
               or "NOT_SHIPPED" in prompt,
               prompt[:300])
        _check("prompt embeds the relevance pack header",
               "RELEVANCE PACK for NC-BP" in prompt,
               prompt[:400])
        _check("prompt embeds the Task section from the pack",
               "## Task" in prompt, prompt[:600])
        _check("prompt embeds the Likely touched files section",
               "## Likely touched files" in prompt, prompt[:600])
        _check("prompt shows the canary excerpt from src/a.ts",
               "BUILD_PROMPT_CANARY" in prompt, prompt[-400:])
        _check("prompt ends with v1 schema RESPONSE FORMAT block",
               "RESPONSE FORMAT" in prompt
               and "schema_version" in prompt,
               prompt[-500:])
        _check("prompt requires SHIPPED+evidence+high-confidence",
               "evidence[]" in prompt and "high" in prompt,
               prompt[-500:])




# ---------------------------------------------------------------------------
# F5.4d — response-size caps in the schema instructions. Live probe data
# (n=3) showed shipped_check latency tracked output tokens, not pack size;
# these caps are the primary quality-preserving lever against the <20s
# budget. See feedback_f5_tuning_levers.md.
# ---------------------------------------------------------------------------

def test_prompt_includes_response_size_caps() -> None:
    """shipped_check prompt must instruct the model to cap evidence[] at 3,
    open_questions[] at 2, and keep summary + excerpts terse. Prompt-level
    caps are the first lever because latency scales with output tokens."""
    import tempfile
    print("\n[test] schema instructions include response-size caps")
    with tempfile.TemporaryDirectory() as tmp:
        proj = Path(tmp) / "proj"
        proj.mkdir()
        task_file = proj / "task.md"
        task_file.write_text("# NC-CAP\n\n## AC\n- x\n")
        prompt = shipped_check.assemble_prompt(
            task_text=task_file.read_text(),
            task_id="NC-CAP",
            project_path=str(proj),
            session_dir=None,
        )
        _check("prompt caps evidence[] at 3",
               "Maximum 3 `evidence[]`" in prompt,
               prompt[-800:])
        _check("prompt caps open_questions[] at 2",
               "Maximum 2 `open_questions[]`" in prompt,
               prompt[-800:])
        _check("prompt instructs summary to one sentence by default",
               "one sentence" in prompt,
               prompt[-800:])
        _check("prompt instructs excerpts to be short",
               "short line" in prompt or "not a code block" in prompt,
               prompt[-800:])

# ---------------------------------------------------------------------------
# inject-partial — task_context.md augmentation on PARTIAL verdicts.
# ---------------------------------------------------------------------------

def test_inject_partial_block_format() -> None:
    """inject-partial writes a block with header, summary, evidence,
    open-questions, the one-line planner/auditor instruction, --- separator,
    then the original task spec preserved below."""
    import tempfile
    print("\n[test] inject-partial produces the 6-part PARTIAL block")
    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        task_file = tmpdir / "task_context.md"
        original_spec = "# NC-42 [P] Do thing\n\n## AC\n- AC-1 handler works\n"
        task_file.write_text(original_spec)

        verdict = {
            "schema_version": 1,
            "verdict": "PARTIAL",
            "confidence": "medium",
            "summary": "AC-1 already landed in handlers.ts",
            "evidence": [
                {"type": "file", "ref": "src/handlers.ts:10",
                 "excerpt": "export function handle(req)"},
            ],
            "open_questions": ["Does AC-2 still need a tenant check?"],
        }
        vj = tmpdir / "verdict.json"
        vj.write_text(json.dumps(verdict))

        shipped_check.inject_partial_cli(str(task_file), str(vj))
        out = task_file.read_text()

        _check("header present",
               "## Shipped-task check: PARTIAL" in out, out[:200])
        _check("summary present",
               "AC-1 already landed in handlers.ts" in out, out[:400])
        _check("evidence header present",
               "**Evidence:**" in out, out[:500])
        _check("evidence bullet rendered",
               "src/handlers.ts:10" in out and "handle(req)" in out,
               out[:600])
        _check("open_questions header present",
               "**Open questions:**" in out, out[:700])
        _check("open_questions bullet rendered",
               "Does AC-2 still need a tenant check?" in out, out[:800])
        _check("planner/auditor instruction present",
               "Planner and auditor: extend existing work" in out, out[-400:])
        _check("separator present",
               "\n---\n" in out, out[-200:])
        _check("original spec preserved at end",
               original_spec.strip() in out, out[-400:])
        _check("block precedes separator precedes original spec",
               out.index("## Shipped-task check")
               < out.index("\n---\n")
               < out.index("# NC-42"))


def test_inject_partial_preserves_original_once() -> None:
    """On first call, task_context.original.md is created as a snapshot of
    the first-seen task spec. Subsequent calls (retries, resume) must NOT
    overwrite .original.md — it stays pinned to the first-seen content even
    if task_context.md has since been augmented."""
    import tempfile
    print("\n[test] inject-partial preserves .original.md once (retry-safe)")
    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        task_file = tmpdir / "task_context.md"
        first_spec = "FIRST-SPEC\n\n- original AC line\n"
        task_file.write_text(first_spec)

        verdict = {"verdict": "PARTIAL", "summary": "s",
                   "evidence": [], "open_questions": []}
        vj = tmpdir / "verdict.json"
        vj.write_text(json.dumps(verdict))

        shipped_check.inject_partial_cli(str(task_file), str(vj))
        original_path = tmpdir / "task_context.original.md"
        _check(".original.md created on first call",
               original_path.exists(), str(original_path))
        _check(".original.md contains first-seen spec",
               original_path.read_text() == first_spec,
               repr(original_path.read_text())[:200])
        _check("task_context.md contains first spec after first call",
               first_spec.strip() in task_file.read_text())

        # Simulate a second inject (retry / resume). At this point
        # task_context.md already has a block prepended. Running inject-partial
        # again must rebuild from .original.md, NOT from the augmented file.
        shipped_check.inject_partial_cli(str(task_file), str(vj))
        _check(".original.md unchanged on second call",
               original_path.read_text() == first_spec)

        # Retry output should still contain exactly one copy of the original
        # spec — not the first-call augmented file appended onto itself.
        rewritten = task_file.read_text()
        _check("retried task_context contains exactly one copy of first spec",
               rewritten.count("FIRST-SPEC") == 1,
               f"count={rewritten.count('FIRST-SPEC')}")
        _check("retried task_context has exactly one block header",
               rewritten.count("## Shipped-task check:") == 1,
               f"count={rewritten.count('## Shipped-task check:')}")


def test_inject_partial_sparse_verdict() -> None:
    """Sparse verdicts (empty evidence[] / open_questions[]) should still
    produce a readable block — the empty sub-sections are omitted rather than
    rendered as bare '**Evidence:**\n' headers."""
    import tempfile
    print("\n[test] inject-partial omits empty subsections on sparse verdict")
    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        task_file = tmpdir / "task_context.md"
        task_file.write_text("# NC-99\n\nbody\n")

        verdict = {"verdict": "PARTIAL", "summary": "", "evidence": [],
                   "open_questions": []}
        vj = tmpdir / "verdict.json"
        vj.write_text(json.dumps(verdict))

        shipped_check.inject_partial_cli(str(task_file), str(vj))
        out = task_file.read_text()

        _check("header still present",
               "## Shipped-task check: PARTIAL" in out, out[:200])
        _check("no empty Evidence header",
               "**Evidence:**" not in out, out[:300])
        _check("no empty Open questions header",
               "**Open questions:**" not in out, out[:300])
        _check("instruction line still present",
               "Planner and auditor: extend existing work" in out, out[:400])
        _check("separator still present", "\n---\n" in out, out[:400])
        _check("original body preserved",
               "body" in out and "# NC-99" in out, out[-200:])


def test_inject_partial_block_format_standalone() -> None:
    """format_partial_block() is a pure function — no file IO. Verifies the
    block shape independent of the CLI wrapper (so bash integration tests can
    assert against the same invariant without touching the filesystem)."""
    print("\n[test] format_partial_block is pure and covers all sections")
    block = shipped_check.format_partial_block({
        "verdict": "PARTIAL",
        "summary": "sum",
        "evidence": [{"type": "commit", "ref": "abc123",
                      "excerpt": "feat: thing"}],
        "open_questions": ["q?"],
    })
    _check("pure-function block has header",
           "## Shipped-task check: PARTIAL" in block, block[:120])
    _check("pure-function block has summary", "**Summary:** sum" in block,
           block[:300])
    _check("pure-function block has evidence entry",
           "(commit)" in block and "abc123" in block, block[:400])
    _check("pure-function block has open_questions entry",
           "- q?" in block, block[:500])
    _check("pure-function block ends with ---",
           block.rstrip().endswith("---"), repr(block[-100:]))


# ---------------------------------------------------------------------------
# Sanity: prompt file is shipped alongside the script.
# ---------------------------------------------------------------------------

def test_prompt_file_present_and_non_empty() -> None:
    print("\n[test] scripts/prompts/shipped_check.md exists and is non-trivial")
    p = shipped_check.PROMPT_PATH
    _check("prompt file exists", p.exists(), str(p))
    if p.exists():
        body = p.read_text()
        _check("prompt file is substantive (>1 KB)", len(body) > 1000,
               f"{len(body)} bytes")
        _check("prompt mentions all four verdicts",
               all(v in body for v in
                   ("SHIPPED", "PARTIAL", "NOT_SHIPPED", "UNCERTAIN")),
               "missing verdict coverage in prompt")


def main() -> int:
    test_shipped_with_evidence_high_confidence_preserved()
    test_partial_preserved()
    test_not_shipped_passes_through()
    test_uncertain_preserved()
    test_shipped_without_evidence_coerced()
    test_shipped_with_low_confidence_coerced()
    test_invalid_verdict_coerced()
    test_unparseable_falls_back_to_uncertain()
    test_empty_input_falls_back_to_uncertain()
    test_fenced_json_extracted()
    test_json_in_preamble_prose_extracted()
    test_missing_fields_filled_with_defaults()
    test_malformed_evidence_list_sanitized()
    test_unknown_confidence_normalised()
    test_schema_version_non_int_falls_back()
    test_module_does_not_import_call_codex()
    test_build_prompt_emits_pack_persona_and_schema()
    test_prompt_includes_response_size_caps()
    test_inject_partial_block_format()
    test_inject_partial_preserves_original_once()
    test_inject_partial_sparse_verdict()
    test_inject_partial_block_format_standalone()
    test_prompt_file_present_and_non_empty()

    print()
    if _FAIL:
        print(f"FAILED: {len(_FAIL)} assertion(s)")
        for f in _FAIL:
            print(f"  - {f}")
        return 1
    print("ALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
