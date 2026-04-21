#!/usr/bin/env python3
"""F6a contract tests — complexity_tier.derive_tier behavior.

Runs standalone (no pytest required). Exit code: 0 = all pass, 1 = any fail.

Run with:
    python3 tests/test_complexity_tier.py
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from lib import complexity_tier as ct  # noqa: E402

_FAIL = []


def _check(label: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"  PASS  {label}")
    else:
        print(f"  FAIL  {label}" + (f" — {detail}" if detail else ""))
        _FAIL.append(label)


# -----------------------------------------------------------------------------
# Fixtures — shape-realistic task bodies
# -----------------------------------------------------------------------------

TRIVIAL_TASK = """\
#### NC-001 [ ] Rename a label in the settings page

**The gap:** The current label says "Profile settings". It should say
"Account settings" for consistency with the sidebar nav entry.

**What this task ships:** Change the one string literal.

**Files:**
- `apps/web/src/components/settings/header.tsx` (1-line string change)

### Acceptance
- Header renders "Account settings" instead of "Profile settings".
- No other string changes.
"""

STANDARD_TASK = """\
#### NC-002 [ ] Add a compact trend chart to the dashboard KPI strip

**The gap:** The KPI strip shows single numbers. Owners want a
7-day sparkline alongside each KPI to see direction at a glance.

**Implementation shape:**
- New `<KpiSparkline>` component rendering a minimal inline SVG line chart.
- Wire into the three existing KPI tiles in the strip.
- Data shape: `{points: number[]}` passed in by the parent.
- Use existing `recentExpenses` query output; compute last-7-day rollup client-side.

**Files:**
- `apps/web/src/components/dashboard/kpi-sparkline.tsx` (new)
- `apps/web/src/components/dashboard/kpi-strip.tsx` (edit)
- `apps/web/src/lib/rollup.ts` (new helper)
- `apps/web/src/__tests__/kpi-sparkline.test.tsx` (new)

### Acceptance
- Sparkline renders inline on each of the three KPI tiles.
- Empty-data case renders a flat line, not a crash.
- Unit tests cover the rollup helper across timezone boundaries.
- No regression on the existing KPI number rendering.
"""

RISKY_TASK = """\
#### NC-003 [ ] Introduce schema migration for tenant.feature_flags

**The gap:** Feature flags currently live in a blob column. We need
a proper migration to move them to a dedicated table with tenant-scoped
RLS so future flag lookups are efficient and auditable.

**Implementation shape:**
- New Drizzle migration creating `tenant_feature_flags` table.
- Backfill step copying the existing blob into rows.
- RLS policy enforcing tenant scope.
- Update the auth middleware path that reads flags to use the new table.

**Files:**
- `apps/api/migrations/0042_tenant_feature_flags.sql` (new)
- `apps/api/src/db/schema.ts` (edit)
- `apps/api/src/auth/flags.ts` (edit)

### Acceptance
- Migration applies cleanly against a seeded fixture DB.
- Old blob column deprecated, not yet dropped (safety).
- Unit tests cover the new flags read path through auth middleware.
- RLS smoke test — cross-tenant access blocked.
"""

EDGE_EXACTLY_TWO_AC_ONE_FILE = """\
#### NC-004 [ ] Tiny helper

**Files:**
- `apps/web/src/lib/helper.ts`

### Acceptance
- Function returns new default.
- Existing callers unaffected.
"""

EDGE_THREE_AC_ONE_FILE = """\
#### NC-005 [ ] Slightly bigger

**Files:**
- `apps/web/src/lib/helper.ts`

### Acceptance
- Function returns new default.
- Existing callers unaffected.
- Unit test covers the new branch.
"""

EDGE_TWO_AC_TWO_FILES = """\
#### NC-006 [ ] Two files

**Files:**
- `apps/web/src/lib/helper.ts`
- `apps/web/src/lib/other.ts`

### Acceptance
- Function returns new default.
- Existing callers unaffected.
"""

EDGE_NO_AC_SECTION = """\
#### NC-007 [ ] No acceptance section

**Implementation shape:**
- Tiny edit in one file.
- Update a string.
"""

EDGE_DELETE_IN_UI_TASK = """\
#### NC-008 [ ] Add a delete button to the expense row

**What this task ships:** A trash icon that triggers the existing
`deleteExpense` mutation. Pure UI wiring.

**Files:**
- `apps/web/src/components/advisor/expense-section.tsx`

### Acceptance
- Clicking trash icon fires the mutation.
- Optimistic row removal.
"""


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_trivial_one_file_two_ac() -> None:
    tier, signals = ct.derive_tier(TRIVIAL_TASK)
    _check("trivial: tier is TRIVIAL", tier == "TRIVIAL", f"got {tier}")
    _check("trivial: listed_files=1", signals["listed_files"] == 1, str(signals))
    _check("trivial: ac_count=2", signals["ac_count"] == 2, str(signals))
    _check("trivial: no keywords", signals["keywords"] == [], str(signals))


def test_standard_multi_file_multi_ac() -> None:
    tier, signals = ct.derive_tier(STANDARD_TASK)
    _check("standard: tier is STANDARD", tier == "STANDARD", f"got {tier}")
    _check("standard: listed_files>=3", signals["listed_files"] >= 3, str(signals))
    _check("standard: ac_count>=3", signals["ac_count"] >= 3, str(signals))
    _check("standard: no keywords", signals["keywords"] == [], str(signals))


def test_risky_schema_migration_auth() -> None:
    tier, signals = ct.derive_tier(RISKY_TASK)
    _check("risky: tier is RISKY", tier == "RISKY", f"got {tier}")
    for kw in ("migration", "schema", "auth"):
        _check(f"risky: keyword {kw!r} hit", kw in signals["keywords"], str(signals))
    # Canonical order preserved.
    order = ["migration", "schema", "auth", "crypto", "delete", "drop"]
    got = signals["keywords"]
    _check(
        "risky: keywords in canonical order",
        got == [k for k in order if k in got],
        str(got),
    )


def test_edge_exactly_two_ac_one_file_is_trivial() -> None:
    tier, signals = ct.derive_tier(EDGE_EXACTLY_TWO_AC_ONE_FILE)
    _check("edge2x1: tier is TRIVIAL", tier == "TRIVIAL", f"got {tier}")
    _check("edge2x1: ac_count=2", signals["ac_count"] == 2, str(signals))
    _check("edge2x1: listed_files=1", signals["listed_files"] == 1, str(signals))


def test_edge_three_ac_promotes_to_standard() -> None:
    tier, signals = ct.derive_tier(EDGE_THREE_AC_ONE_FILE)
    _check("edge3x1: tier is STANDARD", tier == "STANDARD", f"got {tier}")
    _check("edge3x1: ac_count=3", signals["ac_count"] == 3, str(signals))


def test_edge_two_files_promotes_to_standard() -> None:
    tier, signals = ct.derive_tier(EDGE_TWO_AC_TWO_FILES)
    _check("edge2x2: tier is STANDARD", tier == "STANDARD", f"got {tier}")
    _check("edge2x2: listed_files=2", signals["listed_files"] == 2, str(signals))


def test_edge_no_ac_section_falls_back_to_total_bullets() -> None:
    tier, signals = ct.derive_tier(EDGE_NO_AC_SECTION)
    _check(
        "no-ac-section: ac_count=2 via fallback",
        signals["ac_count"] == 2,
        str(signals),
    )
    _check(
        "no-ac-section: listed_files=0",
        signals["listed_files"] == 0,
        str(signals),
    )
    _check("no-ac-section: tier is TRIVIAL", tier == "TRIVIAL", f"got {tier}")


def test_edge_delete_keyword_in_ui_task_forces_risky() -> None:
    # This demonstrates the heuristic IS mis-calibrated for UI-undo
    # tasks that mention "delete" — exactly the F6a calibration signal
    # we want to capture via tier_mismatch.
    tier, signals = ct.derive_tier(EDGE_DELETE_IN_UI_TASK)
    _check("ui-delete: tier is RISKY", tier == "RISKY", f"got {tier}")
    _check(
        "ui-delete: 'delete' keyword captured",
        "delete" in signals["keywords"],
        str(signals),
    )


def test_edge_empty_input() -> None:
    tier, signals = ct.derive_tier("")
    _check("empty: tier is TRIVIAL", tier == "TRIVIAL", f"got {tier}")
    _check(
        "empty: signals zeroed",
        signals == {"ac_count": 0, "listed_files": 0, "keywords": []},
        str(signals),
    )


def test_keyword_word_boundary() -> None:
    # "authentication" must not hit "auth"; "authorize" must not hit "auth".
    body = "This task refactors the authentication-free onboarding flow. No authorize calls."
    _, signals = ct.derive_tier(body)
    _check(
        "word-boundary: 'authentication' does not hit 'auth'",
        "auth" not in signals["keywords"],
        str(signals),
    )


def test_keyword_case_insensitive() -> None:
    body = "Title\n\n## Acceptance\n- Schema change\n"
    _, signals = ct.derive_tier(body)
    _check(
        "case-insensitive: 'Schema' hits 'schema'",
        "schema" in signals["keywords"],
        str(signals),
    )


def test_file_dedup() -> None:
    body = "- `apps/web/foo.ts`\n- `apps/web/foo.ts` (edit)\n"
    _, signals = ct.derive_tier(body)
    _check(
        "file-dedup: same path counted once",
        signals["listed_files"] == 1,
        str(signals),
    )


# -----------------------------------------------------------------------------
# CLI contract
# -----------------------------------------------------------------------------


def test_cli_reads_stdin_writes_json() -> None:
    module_path = ROOT / "scripts" / "lib" / "complexity_tier.py"
    proc = subprocess.run(
        [sys.executable, str(module_path)],
        input=TRIVIAL_TASK,
        capture_output=True,
        text=True,
        timeout=10,
    )
    _check("cli: exit 0", proc.returncode == 0, proc.stderr)
    _check("cli: no stderr", proc.stderr == "", proc.stderr)
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        _check("cli: stdout is JSON", False, f"{e}: {proc.stdout!r}")
        return
    _check("cli: tier=TRIVIAL", payload["tier"] == "TRIVIAL", str(payload))
    _check("cli: ac_count=2", payload["signals"]["ac_count"] == 2, str(payload))
    _check("cli: listed_files=1", payload["signals"]["listed_files"] == 1, str(payload))


def test_cli_empty_input() -> None:
    module_path = ROOT / "scripts" / "lib" / "complexity_tier.py"
    proc = subprocess.run(
        [sys.executable, str(module_path)],
        input="",
        capture_output=True,
        text=True,
        timeout=10,
    )
    _check("cli-empty: exit 0", proc.returncode == 0, proc.stderr)
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        _check("cli-empty: stdout is JSON", False, str(e))
        return
    _check("cli-empty: tier=TRIVIAL", payload["tier"] == "TRIVIAL", str(payload))


# -----------------------------------------------------------------------------


def main() -> int:
    test_trivial_one_file_two_ac()
    test_standard_multi_file_multi_ac()
    test_risky_schema_migration_auth()
    test_edge_exactly_two_ac_one_file_is_trivial()
    test_edge_three_ac_promotes_to_standard()
    test_edge_two_files_promotes_to_standard()
    test_edge_no_ac_section_falls_back_to_total_bullets()
    test_edge_delete_keyword_in_ui_task_forces_risky()
    test_edge_empty_input()
    test_keyword_word_boundary()
    test_keyword_case_insensitive()
    test_file_dedup()
    test_cli_reads_stdin_writes_json()
    test_cli_empty_input()

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
