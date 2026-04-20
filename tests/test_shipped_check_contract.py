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
