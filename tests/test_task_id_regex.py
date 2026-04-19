#!/usr/bin/env python3
"""Regression test for nightcrawler.sh task-ID parser regex.

The regex lives in scripts/nightcrawler.sh inside pick_next_task().
Historic pattern '[A-Z]+-[0-9A-Z]+' truncated multi-segment IDs
(e.g. NC-F1-VALIDATE -> NC-F1), which starved downstream phases of
the correct task body and left the relevance pack nearly empty.

This test locks in two guarantees:
  (a) single-segment IDs still match (back-compat)
  (b) multi-segment IDs match in full (the fix)

Plus it checks the script actually carries the new regex inline, so a
future well-meaning refactor can't silently regress the flow.

Run with:
    python3 tests/test_task_id_regex.py
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "nightcrawler.sh"

# Must stay in sync with scripts/nightcrawler.sh:pick_next_task.
PATTERN = r"[A-Z]+-[0-9A-Z]+(-[0-9A-Z]+)*"

_FAIL: list[str] = []


def _check(label: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"  PASS  {label}")
    else:
        print(f"  FAIL  {label}" + (f" -- {detail}" if detail else ""))
        _FAIL.append(label)


def _extract(answer: str) -> str:
    """Mimic the shell pipeline: echo "$answer" | grep -oE PATTERN | head -1."""
    result = subprocess.run(
        ["grep", "-oE", PATTERN],
        input=answer,
        capture_output=True,
        text=True,
        check=False,
    )
    lines = result.stdout.splitlines()
    return lines[0] if lines else ""


def test_single_segment_back_compat() -> None:
    print("\n[test] single-segment IDs still match")
    _check("NC-385 -> NC-385", _extract("NC-385") == "NC-385")
    _check("CAM-001 -> CAM-001", _extract("CAM-001") == "CAM-001")
    _check("NC-SMOKE -> NC-SMOKE", _extract("NC-SMOKE") == "NC-SMOKE")
    _check("ABC-42Z -> ABC-42Z (mixed alnum segment)", _extract("ABC-42Z") == "ABC-42Z")


def test_multi_segment_full_match() -> None:
    print("\n[test] multi-segment IDs match in full (the fix)")
    _check(
        "NC-F1-VALIDATE fully matched",
        _extract("NC-F1-VALIDATE") == "NC-F1-VALIDATE",
    )
    _check(
        "CAM-F1-SMOKE-V2 fully matched",
        _extract("CAM-F1-SMOKE-V2") == "CAM-F1-SMOKE-V2",
    )
    _check(
        "NC-449-HOTFIX fully matched",
        _extract("NC-449-HOTFIX") == "NC-449-HOTFIX",
    )
    _check(
        "NC-42A-B-C (three extensions) fully matched",
        _extract("NC-42A-B-C") == "NC-42A-B-C",
    )


def test_extract_from_free_text() -> None:
    print("\n[test] extract ID from surrounding model answer")
    _check(
        "free-text answer containing multi-segment ID",
        _extract("The next task is NC-F1-VALIDATE in the queue.") == "NC-F1-VALIDATE",
    )
    _check(
        "ID followed by punctuation",
        _extract("Pick: NC-F1-VALIDATE.") == "NC-F1-VALIDATE",
    )
    _check(
        "ID followed by bracket boundary",
        _extract("#### NC-F1-VALIDATE [ ] title") == "NC-F1-VALIDATE",
    )
    _check("NONE answer -> empty string", _extract("NONE") == "")
    _check("empty input -> empty string", _extract("") == "")


def test_lowercase_terminates_chain() -> None:
    print("\n[test] lowercase terminator stops segment extension")
    # IDs use only uppercase/digits. A lowercase char must not be absorbed
    # into the ID, otherwise prose after the ID could get swallowed.
    _check(
        "NC-SMOKE-v2 -> NC-SMOKE (lowercase v stops chain)",
        _extract("NC-SMOKE-v2") == "NC-SMOKE",
    )
    _check(
        "NC-F1-validate (lowercase) -> NC-F1",
        _extract("NC-F1-validate") == "NC-F1",
    )


def test_script_inline_matches_expected_pattern() -> None:
    """Guardrail: refuse to silently diverge from the regex this test locks in."""
    print("\n[test] nightcrawler.sh carries the expected regex inline")
    text = SCRIPT.read_text()
    expected = "grep -oE '[A-Z]+-[0-9A-Z]+(-[0-9A-Z]+)*'"
    _check(
        "pick_next_task uses multi-segment-capable regex",
        expected in text,
        detail=f"did not find {expected!r} in {SCRIPT}",
    )


def main() -> int:
    for t in (
        test_single_segment_back_compat,
        test_multi_segment_full_match,
        test_extract_from_free_text,
        test_lowercase_terminates_chain,
        test_script_inline_matches_expected_pattern,
    ):
        t()
    print("\n" + ("OK" if not _FAIL else f"FAILED: {_FAIL}"))
    return 0 if not _FAIL else 1


if __name__ == "__main__":
    sys.exit(main())
