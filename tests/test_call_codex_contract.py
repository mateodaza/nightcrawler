#!/usr/bin/env python3
"""B0 contract tests — parse_structured_verdict behavior.

Runs standalone (no pytest required). Exit code: 0 = all pass, 1 = any fail.

Run with:
    python3 tests/test_call_codex_contract.py
"""

import json
import sys
from pathlib import Path

# Make scripts/ importable without polluting PYTHONPATH globally.
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import call_codex  # noqa: E402


_FAIL = []


def _check(label: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"  PASS  {label}")
    else:
        print(f"  FAIL  {label}" + (f" — {detail}" if detail else ""))
        _FAIL.append(label)


def test_approved_passthrough() -> None:
    print("\n[test] v2 APPROVED passthrough")
    src = json.dumps({
        "verdict": "APPROVED",
        "blocking_issues": [],
        "advisories": [],
        "irrelevant": [],
        "complexity_tier": "STANDARD",
        "confidence": "high",
        "why_confident": "spec matches impl",
        "what_would_change_my_mind": "new AC",
        "schema_version": 2,
    })
    out = call_codex.parse_structured_verdict(src)
    _check("verdict preserved", out["verdict"] == "APPROVED")
    _check("schema_version=2", out["schema_version"] == 2)
    _check("no contract_violations key", "contract_violations" not in out)
    _check("feedback rendered", out["feedback"] == "APPROVED")


def test_rejected_concrete_preserved() -> None:
    print("\n[test] v2 REJECTED with concrete blocking_issues")
    src = json.dumps({
        "verdict": "REJECTED",
        "blocking_issues": [{
            "reference": "AC 3: tenant isolation",
            "current_state": "query omits tenant_id",
            "required_change": "add tenant_id to WHERE in src/db/leads.ts:47",
            "severity": "high",
        }],
        "advisories": [],
        "irrelevant": [],
        "complexity_tier": "RISKY",
        "confidence": "high",
        "why_confident": "clear violation",
        "what_would_change_my_mind": "if tenant_id is enforced at another layer",
        "schema_version": 2,
    })
    out = call_codex.parse_structured_verdict(src)
    _check("verdict stays REJECTED", out["verdict"] == "REJECTED")
    _check("blocking_issues preserved", len(out["blocking_issues"]) == 1)
    _check("no coercion fired", "contract_violations" not in out)
    _check("feedback contains required_change",
           "tenant_id to WHERE" in out["feedback"],
           out["feedback"])


def test_vague_rejection_coerced() -> None:
    print("\n[test] REJECTED with empty blocking_issues is coerced")
    src = json.dumps({
        "verdict": "REJECTED",
        "blocking_issues": [],
        "advisories": [],
        "irrelevant": [],
        "complexity_tier": "STANDARD",
        "confidence": "medium",
        "why_confident": "something feels off",
        "what_would_change_my_mind": "not sure",
        "schema_version": 2,
    })
    out = call_codex.parse_structured_verdict(src)
    _check("verdict coerced to APPROVED", out["verdict"] == "APPROVED")
    _check("violation flag fired",
           "vague_rejection_coerced" in out.get("contract_violations", []))
    _check("advisory added explaining coercion",
           any("Coerced" in (a.get("rationale", "") or "") or "coerced" in (a.get("rationale", "") or "").lower()
               for a in out["advisories"]),
           str(out["advisories"]))


def test_fence_stripping() -> None:
    print("\n[test] ```json fences are stripped")
    src = "```json\n" + json.dumps({
        "verdict": "APPROVED",
        "blocking_issues": [],
        "advisories": [{"note": "tiny nit", "rationale": "style"}],
        "irrelevant": [],
        "complexity_tier": "TRIVIAL",
        "confidence": "high",
        "why_confident": "clean",
        "what_would_change_my_mind": "new AC",
        "schema_version": 2,
    }) + "\n```"
    out = call_codex.parse_structured_verdict(src)
    _check("verdict parsed", out["verdict"] == "APPROVED")
    _check("schema_version=2 (not fallback)", out["schema_version"] == 2)
    _check("advisory preserved", len(out["advisories"]) == 1)


def test_v1_fallback_rejected() -> None:
    print("\n[test] Free-form REJECTED text → v1 fallback")
    src = "REJECTED: missing reentrancy guard on withdraw()"
    out = call_codex.parse_structured_verdict(src)
    _check("verdict=REJECTED", out["verdict"] == "REJECTED")
    _check("schema_version=1 (fallback)", out["schema_version"] == 1)
    _check("unparseable_v2 flag fired",
           "unparseable_v2" in out.get("contract_violations", []))
    _check("original text preserved in blocking_issues so regex matchers still work",
           len(out["blocking_issues"]) == 1 and
           "reentrancy" in out["blocking_issues"][0].get("required_change", ""))
    _check("feedback contains original text for check_impl_lock",
           "reentrancy" in out["feedback"])


def test_v1_fallback_approved() -> None:
    print("\n[test] Free-form APPROVED text → v1 fallback")
    src = "APPROVED — this looks good"
    out = call_codex.parse_structured_verdict(src)
    _check("verdict=APPROVED", out["verdict"] == "APPROVED")
    _check("schema_version=1 (fallback)", out["schema_version"] == 1)
    _check("no blocking_issues synthesized on APPROVED", len(out["blocking_issues"]) == 0)


def test_empty_input() -> None:
    print("\n[test] Empty input → UNCLEAR v1")
    out = call_codex.parse_structured_verdict("")
    _check("verdict=UNCLEAR", out["verdict"] == "UNCLEAR")
    _check("schema_version=1", out["schema_version"] == 1)


def test_persona_loader_generic_fallback() -> None:
    print("\n[test] persona loader falls back to generic when project missing")
    # /nonexistent → generic persona
    persona = call_codex._load_audit_persona("/nonexistent/project")
    _check("generic persona returned", "independent code auditor" in persona.lower())


def test_persona_loader_reads_project_file() -> None:
    print("\n[test] persona loader reads project-specific file")
    # The persona files live at config/projects/<name>/audit-persona.md
    # Set project_path to any path whose basename is 'camello' and the loader
    # resolves to config/projects/camello/audit-persona.md relative to repo root.
    persona_camello = call_codex._load_audit_persona("/home/nightcrawler/projects/camello")
    _check("camello persona loaded", "Camello" in persona_camello or "TypeScript" in persona_camello,
           persona_camello[:200])
    persona_clout = call_codex._load_audit_persona("/home/nightcrawler/projects/clout")
    _check("clout persona loaded (Solidity mention)",
           "Solidity" in persona_clout or "Foundry" in persona_clout,
           persona_clout[:200])
    _check("camello persona does NOT contain Solidity",
           "Solidity" not in persona_camello,
           persona_camello[:200])


def main() -> int:
    test_approved_passthrough()
    test_rejected_concrete_preserved()
    test_vague_rejection_coerced()
    test_fence_stripping()
    test_v1_fallback_rejected()
    test_v1_fallback_approved()
    test_empty_input()
    test_persona_loader_generic_fallback()
    test_persona_loader_reads_project_file()

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
