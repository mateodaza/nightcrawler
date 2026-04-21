#!/usr/bin/env python3
"""F6a + F6b.1 contract tests — complexity_tier.derive_tier behavior.

Runs standalone (no pytest required). Exit code: 0 = all pass, 1 = any fail.

Run with:
    python3 tests/test_complexity_tier.py

F6b.1 additions (this file):
    - Lever 1: prohibition-section stripping (Non-goals / Do NOT / Don't / Never)
    - Lever 2: negation window (no/not/without/never/nor/cannot/n't ≤ 5 tokens)
    - Lever 3: RISKY gate requires ≥2 distinct keywords OR ≥1 keyword + files>1
    - Schema: signals.keywords_raw exposes pre-filter matches for diagnosis
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

# F6b.1: Solo benign keyword in a small UI task. Pre-fix: RISKY (false positive).
# Post-fix: STANDARD (caution preserved, no RISKY shouting).
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

# F6b.1 lever 1: prohibition section drains keywords. NC-405 / NC-402 shape —
# Non-goals lists migration/schema/auth as forbidden surfaces; pre-fix all three
# count as RISKY signals; post-fix all three are stripped before keyword scan.
PROHIBITION_BLOCK_TASK = """\
#### NC-100 [ ] Show category emoji inline with category label

**The gap:** Category labels are plain text. Add the emoji prefix already used
by the chip row.

**Implementation:**
- Locate the category label span in `apps/web/src/components/advisor/expense-section.tsx`.
- Read the emoji from the existing map in `apps/web/src/components/advisor/category-chip.tsx`.
- Render emoji with `mr-1` margin before the label.

### Acceptance
- Each row shows the category emoji before its label.
- Rows with a missing emoji render the label alone.

**Non-goals (do NOT do):**
- Do NOT add or remove any category from `EXPENSE_CATEGORIES` in `packages/shared`.
- Do NOT write a migration — the column is unchanged.
- Do NOT modify the expenses schema or the `listRecentExpenses` tRPC query.
- Do NOT touch auth / tenant scoping / the advisor archetype config.
- Do NOT add a new i18n namespace.
"""

# F6b.1 lever 2: incidental denial-prose mention. NC-404 shape — the line
# "no mutation, schema, or API change" parses as denial; pre-fix `schema` hit
# counted; post-fix the negation window drops it.
NEGATION_DENIAL_TASK = """\
#### NC-101 [ ] Fade row to 50% opacity during pending delete mutation

**The gap:** The row stays visually identical until deleteExpense resolves;
on slow networks the user can re-fire the mutation by mistake.

**What this task ships:** Render the row at `opacity-50 pointer-events-none`
while the mutation is pending. Pure client-side — no mutation, schema, or
API change.

**Files:**
- `apps/web/src/components/advisor/expense-section.tsx`

### Acceptance
- The row dims immediately on click.
- The row cannot be re-clicked while the delete is in flight.
"""

# F6b.1 lever 3 negative case: solo benign keyword + 1 file → STANDARD,
# not RISKY. Same as EDGE_DELETE_IN_UI_TASK but explicit re: gate intent.
SOLO_KEYWORD_SMALL_TASK = """\
#### NC-102 [ ] Reorder row action icons: edit left, delete right

**The gap:** The Delete (trash) icon currently renders before Edit (pencil).
Swap their JSX order.

**Files:**
- `apps/web/src/components/advisor/expense-section.tsx`

### Acceptance
- Edit icon renders to the left of Delete icon in every row.
- No handler changes.
"""

# F6b.1 lever 3 positive case: 5 distinct keywords across multiple files →
# RISKY (genuine multi-surface task). NC-407 shape — preserves the strong
# RISKY signal exactly where it matters.
MULTI_KEYWORD_RISKY_TASK = """\
#### NC-103 [ ] Archive expenses — archivedAt column + archiveExpense mutation

**The gap:** Users want to hide expenses without losing the historical record.
Mirror the `learnings.archivedAt` soft-delete pattern.

**Schema changes (packages/db):**
- Add `archivedAt` timestamp to `packages/db/src/schema/expenses.ts`.
- New migration file `packages/db/migrations/0042_expenses_archived_at.sql`.

**API changes (apps/api/src/routes/advisor.ts):**
- Add `archiveExpense` tenant-scoped mutation.
- Authorization: constrain by `eq(expenses.tenantId, ctx.tenantId)`.
- Update `recentExpenses`: filter `isNull(expenses.archivedAt)`.

**Tests (apps/api/src/__tests__/routes/advisor-expenses.test.ts):**
- archiveExpense sets archivedAt.
- Cross-tenant archive throws NOT_FOUND.
- recentExpenses excludes archived rows.

### Acceptance
- Migration applies cleanly.
- archiveExpense passes the three auth + behavior tests.
- recentExpenses excludes rows where archivedAt IS NOT NULL.
"""

# F6b.1 lever 1 edge: Non-goals followed back-to-back by another section.
# Verify section-strip exits cleanly and keyword in the next section IS counted.
PROHIBITION_THEN_REAL_KW_TASK = """\
#### NC-104 [ ] Mixed shape

**Files:**
- `packages/db/src/schema/foo.ts`
- `apps/api/migrations/0099_foo.sql`

**Non-goals:**
- Do NOT touch auth.

### Acceptance
- migration applies.
- schema unchanged in unrelated tables.
"""


# -----------------------------------------------------------------------------
# Original tests (unchanged where behavior is preserved)
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


def test_empty_input() -> None:
    tier, signals = ct.derive_tier("")
    _check("empty: tier is TRIVIAL", tier == "TRIVIAL", f"got {tier}")
    _check(
        "empty: signals zeroed (with keywords_raw)",
        signals == {
            "ac_count": 0,
            "listed_files": 0,
            "keywords": [],
            "keywords_raw": [],
        },
        str(signals),
    )


def test_keyword_word_boundary() -> None:
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
        "case-insensitive: 'Schema' hits 'schema_raw'",
        "schema" in signals["keywords_raw"],
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
# F6b.1 — Lever 1: prohibition-block stripping
# -----------------------------------------------------------------------------


def test_lever1_prohibition_block_strips_keywords() -> None:
    """NC-405 shape: Non-goals lists migration/schema/auth — all must be stripped."""
    tier, signals = ct.derive_tier(PROHIBITION_BLOCK_TASK)
    _check(
        "lever1: keywords empty after section-strip",
        signals["keywords"] == [],
        str(signals),
    )
    # Pre-strip all three keywords ARE in raw — proves the strip actually fired.
    for kw in ("migration", "schema", "auth"):
        _check(
            f"lever1: keywords_raw includes {kw!r} (pre-strip)",
            kw in signals["keywords_raw"],
            str(signals),
        )
    # 0 kws + 2 files + 2 AC bullets → STANDARD (multi-file pushes off TRIVIAL).
    _check("lever1: tier is STANDARD", tier == "STANDARD", f"got {tier} signals={signals}")


def test_lever1_strip_helper_idempotent() -> None:
    stripped = ct.strip_prohibition_blocks(PROHIBITION_BLOCK_TASK)
    twice = ct.strip_prohibition_blocks(stripped)
    _check(
        "lever1: strip is idempotent",
        stripped == twice,
        f"differ by {len(stripped) - len(twice)} chars",
    )


def test_lever1_back_to_back_section_exit() -> None:
    """Non-goals followed by Files/Acceptance: strip ends, real kws still count."""
    tier, signals = ct.derive_tier(PROHIBITION_THEN_REAL_KW_TASK)
    # 'auth' was inside Non-goals, must be stripped.
    _check(
        "lever1: 'auth' stripped (in Non-goals)",
        "auth" not in signals["keywords"],
        str(signals),
    )
    # 'migration' and 'schema' appear in Acceptance section + as filename — count.
    _check(
        "lever1: 'migration' counted (outside Non-goals)",
        "migration" in signals["keywords"],
        str(signals),
    )
    _check(
        "lever1: 'schema' counted (outside Non-goals)",
        "schema" in signals["keywords"],
        str(signals),
    )
    # 2 keywords + 2 files → RISKY by ≥2-kw gate.
    _check(
        "lever1: tier is RISKY (real kws survive)",
        tier == "RISKY",
        f"got {tier} signals={signals}",
    )


# -----------------------------------------------------------------------------
# F6b.1 — Lever 2: negation window
# -----------------------------------------------------------------------------


def test_lever2_negation_window_drops_denial_kw() -> None:
    """NC-404 shape: 'no mutation, schema, or API change' must drop 'schema'."""
    tier, signals = ct.derive_tier(NEGATION_DENIAL_TASK)
    _check(
        "lever2: 'schema' dropped by negation window",
        "schema" not in signals["keywords"],
        str(signals),
    )
    _check(
        "lever2: 'schema' visible in keywords_raw (pre-filter)",
        "schema" in signals["keywords_raw"],
        str(signals),
    )
    # 'delete' appears multiple times non-negated — must be retained.
    _check(
        "lever2: 'delete' retained (non-negated mentions)",
        "delete" in signals["keywords"],
        str(signals),
    )
    # Net: 1 kw + 1 file → STANDARD by lever 3.
    _check("lever2: tier is STANDARD", tier == "STANDARD", f"got {tier} signals={signals}")


def test_lever2_negation_only_kills_when_all_negated() -> None:
    """If ANY occurrence is non-negated, the keyword is retained."""
    body = (
        "We do NOT delete by default. Later: the delete flow runs to completion.\n"
        "**Files:**\n- `apps/web/foo.ts`\n"
    )
    _, signals = ct.derive_tier(body)
    _check(
        "lever2: 'delete' retained when one mention is non-negated",
        "delete" in signals["keywords"],
        str(signals),
    )


def test_lever2_negation_clitic_kills() -> None:
    """don't / doesn't / can't / won't tokens trigger negation."""
    body = "Don't drop the column. Won't delete records.\n**Files:**\n- `a.ts`\n"
    _, signals = ct.derive_tier(body)
    # 'drop' negated by "Don't"; 'delete' negated by "Won't".
    _check(
        "lever2: clitic 'Don't' negates 'drop'",
        "drop" not in signals["keywords"],
        str(signals),
    )
    _check(
        "lever2: clitic 'Won't' negates 'delete'",
        "delete" not in signals["keywords"],
        str(signals),
    )


def test_lever2_negation_window_size() -> None:
    """Negation > 5 tokens away should NOT trigger."""
    body = "We will not have any other rule and so we now must run a fresh migration today.\n"
    _, signals = ct.derive_tier(body)
    # 'not' is ~10+ tokens before 'migration' — must NOT negate.
    _check(
        "lever2: negation outside 5-token window does not fire",
        "migration" in signals["keywords"],
        str(signals),
    )


# -----------------------------------------------------------------------------
# F6b.1 — Lever 3: ≥2-keyword OR multi-file gate for RISKY
# -----------------------------------------------------------------------------


def test_lever3_solo_keyword_demotes_to_standard() -> None:
    """NC-403 shape: solo 'delete' in a 1-file UI task → STANDARD, not RISKY."""
    tier, signals = ct.derive_tier(SOLO_KEYWORD_SMALL_TASK)
    _check("lever3: solo kw → STANDARD", tier == "STANDARD", f"got {tier}")
    _check(
        "lever3: solo kw retained in keywords",
        signals["keywords"] == ["delete"],
        str(signals),
    )


def test_lever3_solo_keyword_with_multi_file_is_risky() -> None:
    """1 keyword + multi-file → RISKY (broader scope tips the gate)."""
    body = (
        "**The gap:** Update the delete flow.\n\n"
        "**Files:**\n"
        "- `apps/api/src/routes/a.ts`\n"
        "- `apps/api/src/routes/b.ts`\n"
        "- `apps/api/src/routes/c.ts`\n"
        "\n### Acceptance\n- delete works\n- tests pass\n"
    )
    tier, signals = ct.derive_tier(body)
    _check(
        "lever3: 1 kw + 3 files → RISKY",
        tier == "RISKY",
        f"got {tier} signals={signals}",
    )


def test_lever3_two_distinct_keywords_is_risky() -> None:
    """≥2 distinct keywords → RISKY regardless of file count."""
    body = (
        "**The gap:** schema + migration work.\n\n"
        "**Files:**\n- `packages/db/schema.ts`\n"
        "\n### Acceptance\n- migration applies\n- schema valid\n"
    )
    tier, signals = ct.derive_tier(body)
    _check(
        "lever3: 2 distinct kws → RISKY",
        tier == "RISKY",
        f"got {tier} signals={signals}",
    )
    _check(
        "lever3: both kws present",
        set(signals["keywords"]) == {"schema", "migration"},
        str(signals),
    )


def test_lever3_multi_keyword_risky_genuine() -> None:
    """NC-103/NC-407 shape: 5 keywords + multi-file → RISKY."""
    tier, signals = ct.derive_tier(MULTI_KEYWORD_RISKY_TASK)
    _check(
        "lever3: genuine multi-surface → RISKY",
        tier == "RISKY",
        f"got {tier} signals={signals}",
    )
    for kw in ("migration", "schema", "auth", "delete"):
        _check(
            f"lever3-genuine: keyword {kw!r} present",
            kw in signals["keywords"],
            str(signals),
        )


# -----------------------------------------------------------------------------
# F6b.1 — Behavior change: ui-delete (was RISKY, now STANDARD)
# -----------------------------------------------------------------------------


def test_ui_delete_now_demotes_to_standard() -> None:
    """Pre-F6b.1: this was RISKY (false positive). Post-F6b.1: STANDARD."""
    tier, signals = ct.derive_tier(EDGE_DELETE_IN_UI_TASK)
    _check(
        "ui-delete: tier is now STANDARD (was RISKY pre-F6b.1)",
        tier == "STANDARD",
        f"got {tier}",
    )
    _check(
        "ui-delete: 'delete' keyword still captured",
        "delete" in signals["keywords"],
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
    _check(
        "cli: keywords_raw field present",
        "keywords_raw" in payload["signals"],
        str(payload),
    )


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
    test_empty_input()
    test_keyword_word_boundary()
    test_keyword_case_insensitive()
    test_file_dedup()
    # F6b.1 levers
    test_lever1_prohibition_block_strips_keywords()
    test_lever1_strip_helper_idempotent()
    test_lever1_back_to_back_section_exit()
    test_lever2_negation_window_drops_denial_kw()
    test_lever2_negation_only_kills_when_all_negated()
    test_lever2_negation_clitic_kills()
    test_lever2_negation_window_size()
    test_lever3_solo_keyword_demotes_to_standard()
    test_lever3_solo_keyword_with_multi_file_is_risky()
    test_lever3_two_distinct_keywords_is_risky()
    test_lever3_multi_keyword_risky_genuine()
    test_ui_delete_now_demotes_to_standard()
    # CLI
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
