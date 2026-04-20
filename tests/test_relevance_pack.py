#!/usr/bin/env python3
"""F1 contract tests — relevance_pack.build_pack behavior.

Runs standalone (no pytest required). Exit code: 0 = all pass, 1 = any fail.

Each test creates a throwaway project directory in a tempdir so the results
don't depend on the surrounding nightcrawler repo state.

Run with:
    python3 tests/test_relevance_pack.py
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from lib import relevance_pack  # noqa: E402


_FAIL = []


def _check(label: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"  PASS  {label}")
    else:
        print(f"  FAIL  {label}" + (f" — {detail}" if detail else ""))
        _FAIL.append(label)


def _make_project(tmp: Path, files: dict) -> Path:
    """Build a throwaway project at tmp/<name> with the given files."""
    proj = tmp / "proj"
    proj.mkdir(parents=True, exist_ok=True)
    for rel, content in files.items():
        p = proj / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
    # Not every test needs git — init lazily.
    return proj


def _entries_by_path(meta: dict) -> dict:
    return {e["file"]: e for e in meta["entries"]}


# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

def test_task_files_rank1_plan_audit() -> None:
    print("\n[test] ## Files section → rank-1 entries (plan_audit)")
    with tempfile.TemporaryDirectory() as tmp:
        proj = _make_project(Path(tmp), {
            "src/foo.ts": "export const foo = 1;\n",
            "src/bar.ts": "export const bar = 2;\n",
        })
        task = """# NC-TEST

## Files
- src/foo.ts
- src/bar.ts

## Acceptance Criteria
- foo exists
"""
        out = relevance_pack.build_pack(
            task_text=task, task_id="NC-T1", phase="plan_audit",
            project_path=str(proj),
        )
        entries = _entries_by_path(out["meta"])
        _check("src/foo.ts is rank 1",
               entries.get("src/foo.ts", {}).get("rank") == 1,
               str(entries.get("src/foo.ts")))
        _check("src/bar.ts is rank 1",
               entries.get("src/bar.ts", {}).get("rank") == 1,
               str(entries.get("src/bar.ts")))


def test_inline_ref_picked_up() -> None:
    print("\n[test] inline path:line reference → entry")
    with tempfile.TemporaryDirectory() as tmp:
        proj = _make_project(Path(tmp), {
            "app/page.tsx": "export default function Page() { return null }\n",
        })
        task = "Fix the hydration bug at app/page.tsx:42 and verify."
        out = relevance_pack.build_pack(
            task_text=task, task_id="NC-T2", phase="plan_audit",
            project_path=str(proj),
        )
        entries = _entries_by_path(out["meta"])
        e = entries.get("app/page.tsx")
        _check("app/page.tsx entry exists", e is not None,
               str(list(entries)))
        if e:
            _check("reason mentions inline path reference",
                   any("inline path" in r for r in e["reasons"]),
                   str(e["reasons"]))


def test_duplicate_reasons_collapse() -> None:
    print("\n[test] same file from multiple signals → one entry, all reasons")
    with tempfile.TemporaryDirectory() as tmp:
        proj = _make_project(Path(tmp), {
            "src/target.ts": "export const target = 'tenant_isolation';\n",
        })
        task = """# NC-TEST

## Files
- src/target.ts

## Acceptance Criteria
- tenant_isolation enforced

See src/target.ts:10 for the spot.
"""
        out = relevance_pack.build_pack(
            task_text=task, task_id="NC-T3", phase="plan_audit",
            project_path=str(proj),
        )
        entries = _entries_by_path(out["meta"])
        e = entries.get("src/target.ts")
        _check("single entry for src/target.ts", e is not None,
               str(list(entries)))
        if e:
            # Should have rank 1 (highest wins among 1/2/4 candidates).
            _check("kept highest-priority rank (1)", e["rank"] == 1,
                   str(e))
            # Reasons list accumulates distinct entries.
            _check("two or more distinct reasons", len(e["reasons"]) >= 2,
                   str(e["reasons"]))
            # And they're deduped (no literal duplicates).
            _check("no duplicate reason strings",
                   len(e["reasons"]) == len(set(e["reasons"])),
                   str(e["reasons"]))


def test_impl_review_prefers_diff_over_keyword() -> None:
    print("\n[test] impl_review: changed files > keyword-only hits (rank)")
    with tempfile.TemporaryDirectory() as tmp:
        proj = _make_project(Path(tmp), {
            # Changed file — should get rank 1 in review phase.
            "src/changed.ts": "// the-keyword appears here for grep\n",
            # File that will ONLY be caught by keyword — should get rank 5.
            "src/also.ts": "// the-keyword appears here too\n",
        })
        task = """# NC-TEST

## Acceptance Criteria
- the-keyword is still handled
"""
        out = relevance_pack.build_pack(
            task_text=task, task_id="NC-T4", phase="impl_review",
            project_path=str(proj),
            changed_files=["src/changed.ts"],
        )
        entries = _entries_by_path(out["meta"])
        _check("src/changed.ts rank 1 (diff)",
               entries.get("src/changed.ts", {}).get("rank") == 1,
               str(entries.get("src/changed.ts")))
        also = entries.get("src/also.ts")
        _check("src/also.ts is present at higher (worse) rank than diff",
               also is not None and also["rank"] > 1,
               str(also))


def test_excluded_dirs_filtered() -> None:
    print("\n[test] node_modules / .git paths are excluded from entries")
    with tempfile.TemporaryDirectory() as tmp:
        proj = _make_project(Path(tmp), {
            # The keyword matches ALL of these — only the real src file should survive.
            "src/real.ts": "the-canary-keyword lives here\n",
            "node_modules/pkg/index.js": "the-canary-keyword in vendor\n",
            "dist/bundle.js": "the-canary-keyword in build output\n",
            ".next/cache/something.js": "the-canary-keyword in build cache\n",
        })
        task = """# NC-TEST

## Acceptance Criteria
- the-canary-keyword remains valid
"""
        out = relevance_pack.build_pack(
            task_text=task, task_id="NC-T5", phase="plan_audit",
            project_path=str(proj),
        )
        entries = _entries_by_path(out["meta"])
        _check("src/real.ts included",
               "src/real.ts" in entries, str(list(entries)))
        for bad in ("node_modules/pkg/index.js", "dist/bundle.js",
                    ".next/cache/something.js"):
            _check(f"{bad} filtered out",
                   bad not in entries, str(list(entries)))


def test_missing_audit_patterns_silent() -> None:
    print("\n[test] missing audit-patterns.md → no crash, no phantom entry")
    with tempfile.TemporaryDirectory() as tmp:
        # Project name "unlikely_project_name_xyz" — won't have a persona file.
        proj = Path(tmp) / "unlikely_project_name_xyz"
        proj.mkdir(parents=True)
        (proj / "src").mkdir()
        (proj / "src" / "a.ts").write_text("// content\n")
        out = relevance_pack.build_pack(
            task_text="## Files\n- src/a.ts\n\n## AC\n- holds",
            task_id="NC-T6", phase="plan_audit",
            project_path=str(proj),
        )
        entries = _entries_by_path(out["meta"])
        _check("no audit-patterns entry in meta",
               not any("audit-patterns.md" in p for p in entries),
               str(list(entries)))
        _check("pack text mentions F4 fallback",
               "F4 not shipped" in out["text"] or "no audit-patterns" in out["text"])


def test_oversized_file_summarized() -> None:
    print("\n[test] oversized file summarized + flagged in meta")
    with tempfile.TemporaryDirectory() as tmp:
        # ~20KB file — well above the 5KB per-file cap.
        big = "x = 1\n" * 5000
        proj = _make_project(Path(tmp), {"src/big.py": big})
        out = relevance_pack.build_pack(
            task_text="## Files\n- src/big.py\n",
            task_id="NC-T7", phase="plan_audit",
            project_path=str(proj),
        )
        entries = _entries_by_path(out["meta"])
        e = entries.get("src/big.py")
        _check("entry exists", e is not None)
        if e:
            _check("summarized flag set", e.get("summarized") is True,
                   str(e))
            _check("embedded bytes ≤ per-file cap + header",
                   e["bytes"] <= relevance_pack.PER_FILE_EXCERPT_CAP + 200,
                   str(e))


def test_artifact_write_and_attempt_suffix() -> None:
    print("\n[test] artifact_dir writes {txt,meta.json}; collision → .attempt2")
    with tempfile.TemporaryDirectory() as tmp:
        proj = _make_project(Path(tmp), {"src/a.ts": "// a\n"})
        art = Path(tmp) / "session" / "relevance-packs"

        out1 = relevance_pack.build_pack(
            task_text="## Files\n- src/a.ts\n",
            task_id="NC-T8", phase="plan_audit",
            project_path=str(proj),
            artifact_dir=str(art),
        )
        t1 = out1["artifacts"]["text_path"]
        m1 = out1["artifacts"]["meta_path"]
        _check("first .txt written", t1 and Path(t1).exists(), str(t1))
        _check("first .meta.json written", m1 and Path(m1).exists(), str(m1))
        _check("no attempt suffix on first write",
               ".attempt" not in Path(t1).name if t1 else False,
               Path(t1).name if t1 else "")

        out2 = relevance_pack.build_pack(
            task_text="## Files\n- src/a.ts\n",
            task_id="NC-T8", phase="plan_audit",
            project_path=str(proj),
            artifact_dir=str(art),
        )
        t2 = out2["artifacts"]["text_path"]
        _check("second write uses .attempt2 suffix",
               ".attempt2" in Path(t2).name if t2 else False,
               Path(t2).name if t2 else "")
        # Both files still present.
        _check("first pack still on disk", t1 and Path(t1).exists())


def test_prior_findings_scan_scope() -> None:
    print("\n[test] prior findings scan: per-project filter, newest-first, capped")
    with tempfile.TemporaryDirectory() as tmp:
        proj = _make_project(Path(tmp), {"src/a.ts": "// a\n"})
        # Synthetic state/sessions layout.
        state = Path(tmp) / "state"
        sessions = state / "sessions"
        sessions.mkdir(parents=True)
        # Session for THIS project with a real blocking finding.
        s1 = sessions / "sess-001"
        s1.mkdir()
        (s1 / "journal.jsonl").write_text(json.dumps({
            "event": "audit_complete",
            "project": proj.name,
            "task_id": "NC-FOO",
            "blocking_issues": [{"required_change": "add tenant_id to WHERE"}],
        }) + "\n")
        # Session for a DIFFERENT project — should be filtered out.
        s2 = sessions / "sess-002"
        s2.mkdir()
        (s2 / "journal.jsonl").write_text(json.dumps({
            "event": "audit_complete",
            "project": "some_other_project",
            "task_id": "NC-BAR",
            "blocking_issues": [{"required_change": "SHOULD NOT APPEAR"}],
        }) + "\n")
        out = relevance_pack.build_pack(
            task_text="## Files\n- src/a.ts\n",
            task_id="NC-T9", phase="plan_audit",
            project_path=str(proj),
            state_dir=str(state),
        )
        _check("own-project finding shown",
               "NC-FOO" in out["text"], out["text"][-500:])
        _check("other-project finding filtered",
               "SHOULD NOT APPEAR" not in out["text"], "")


def test_current_session_excluded_from_prior_findings() -> None:
    print("\n[test] P1: current session's journal is NOT re-ingested")
    with tempfile.TemporaryDirectory() as tmp:
        proj = _make_project(Path(tmp), {"src/a.ts": "// a\n"})
        state = Path(tmp) / "state"
        sessions = state / "sessions"
        sessions.mkdir(parents=True)

        # Older session — should appear.
        prior = sessions / "sess-prior"
        prior.mkdir()
        (prior / "journal.jsonl").write_text(json.dumps({
            "event": "audit_complete",
            "project": proj.name,
            "task_id": "NC-PRIOR",
            "blocking_issues": [{"required_change": "PRIOR_FINDING_SENTINEL"}],
        }) + "\n")

        # Current session — should be SKIPPED.
        current = sessions / "sess-current"
        current.mkdir()
        (current / "journal.jsonl").write_text(json.dumps({
            "event": "audit_complete",
            "project": proj.name,
            "task_id": "NC-SELF",
            "blocking_issues": [{"required_change": "CURRENT_SELF_SENTINEL"}],
        }) + "\n")

        out = relevance_pack.build_pack(
            task_text="## Files\n- src/a.ts\n",
            task_id="NC-REVIEW", phase="plan_audit",
            project_path=str(proj),
            state_dir=str(state),
            current_session_dir=str(current),
        )
        _check("prior session finding shown",
               "PRIOR_FINDING_SENTINEL" in out["text"],
               out["text"][-600:])
        _check("current session finding filtered out",
               "CURRENT_SELF_SENTINEL" not in out["text"],
               out["text"][-600:])


def test_review_impl_picks_up_untracked_files() -> None:
    """P2 regression: review_impl's internal changed_files derivation must
    include untracked files via `git ls-files --others --exclude-standard`,
    and the synthesized diff body must contain their contents."""
    print("\n[test] P2: untracked files reach both changed_files and diff body")
    # We test via call_codex.review_impl directly with mocked network. The test
    # lives in this file because it covers F1 pack plumbing, but it imports
    # call_codex.
    import os as _os
    saved_flag = _os.environ.get("NC_RELEVANCE_PACK")
    _os.environ["NC_RELEVANCE_PACK"] = "1"
    try:
        import call_codex  # noqa: E402

        with tempfile.TemporaryDirectory() as tmp:
            proj = Path(tmp) / "proj"
            proj.mkdir()
            # git-init and seed with one committed file.
            subprocess.run(["git", "init", "-q"], cwd=proj, check=True)
            subprocess.run(["git", "config", "user.email", "t@t"], cwd=proj, check=True)
            subprocess.run(["git", "config", "user.name", "t"], cwd=proj, check=True)
            (proj / "src").mkdir()
            (proj / "src" / "existing.ts").write_text("// original\n")
            subprocess.run(["git", "add", "-A"], cwd=proj, check=True)
            subprocess.run(["git", "commit", "-qm", "init"], cwd=proj, check=True)

            # Modify the existing file (tracked diff) and create a brand-new
            # untracked file (the blind spot we're fixing).
            (proj / "src" / "existing.ts").write_text("// modified\n")
            (proj / "src" / "brand_new.ts").write_text(
                "// UNTRACKED_CANARY_IMPLEMENTATION\n"
            )

            plan_file = proj / "plan.md"
            plan_file.write_text("## Plan\n1. Add brand_new.ts\n")
            rules_file = proj / "rules.md"
            rules_file.write_text("Be concrete.\n")

            # Mock codex CLI + API, capture the prompt review_impl assembles.
            captured = {}
            orig_cli_available = call_codex.codex_cli_available
            orig_call_api = call_codex.call_api
            call_codex.codex_cli_available = lambda: False

            def _mock_api(sys_p, usr_p, **kw):
                captured["prompt"] = usr_p
                return {
                    "content": json.dumps({
                        "verdict": "APPROVED",
                        "blocking_issues": [], "advisories": [], "irrelevant": [],
                        "complexity_tier": "STANDARD", "confidence": "high",
                        "why_confident": ".", "what_would_change_my_mind": ".",
                        "schema_version": 2,
                    }),
                    "method": "api", "model": "mock", "cost_usd": 0.0,
                    "input_tokens": 0, "output_tokens": 0,
                }

            call_codex.call_api = _mock_api
            try:
                session_dir = proj / "session"
                call_codex.review_impl(
                    str(proj), str(plan_file), str(rules_file),
                    base_branch=None, diff_source=None, test_output_file=None,
                    task_id="NC-P2", session_dir=str(session_dir),
                )
            finally:
                call_codex.codex_cli_available = orig_cli_available
                call_codex.call_api = orig_call_api

            prompt = captured.get("prompt", "")
            _check("untracked file body appears in diff section",
                   "UNTRACKED_CANARY_IMPLEMENTATION" in prompt,
                   prompt[-600:])
            _check("synthesized added-file diff uses /dev/null marker",
                   "--- /dev/null" in prompt and "+++ b/src/brand_new.ts" in prompt,
                   "")
            # And the untracked file should also appear in the relevance pack
            # as a high-priority entry.
            meta_path = session_dir / "relevance-packs" / "NC-P2.impl_review.meta.json"
            _check("meta sidecar written", meta_path.exists(),
                   str(list((session_dir / "relevance-packs").glob("*")) if session_dir.exists() else []))
            if meta_path.exists():
                m = json.loads(meta_path.read_text())
                files = {e["file"]: e for e in m["entries"]}
                brand = files.get("src/brand_new.ts")
                _check("untracked file has an entry", brand is not None,
                       str(list(files)))
                if brand:
                    _check("untracked file got rank 1 (diff)",
                           brand["rank"] == 1, str(brand))
    finally:
        if saved_flag is None:
            _os.environ.pop("NC_RELEVANCE_PACK", None)
        else:
            _os.environ["NC_RELEVANCE_PACK"] = saved_flag


def test_budget_sub_section_isolated() -> None:
    print("\n[test] oversized task body truncates itself, not other sections")
    with tempfile.TemporaryDirectory() as tmp:
        proj = _make_project(Path(tmp), {"src/a.ts": "// small\n"})
        giant_task = "Lorem ipsum " * 1000  # ~12 KB — well above TASK_SPEC_BUDGET (3 KB)
        out = relevance_pack.build_pack(
            task_text="## Files\n- src/a.ts\n\n" + giant_task,
            task_id="NC-T10", phase="plan_audit",
            project_path=str(proj),
        )
        # Task section truncated.
        _check("task section contains truncation sentinel",
               "[task truncated]" in out["text"], "")
        # File excerpt still present.
        _check("file excerpt still rendered despite giant task",
               "// small" in out["text"], "")


def test_bookkeeping_files_demoted_in_impl_review() -> None:
    """Orchestrator-owned PROGRESS.md/TASK_QUEUE.md in changed_files should
    get the lowest rank so real implementation files aren't evicted by them.
    Regression for NC-390 (Apr 2026) where impl_review pack was 100% PROGRESS.md.
    """
    print("\n[test] bookkeeping files demoted in impl_review (rank 99, not rank 1)")
    with tempfile.TemporaryDirectory() as tmp:
        proj = _make_project(Path(tmp), {
            "src/component.tsx": "export const X = () => null;\n" * 20,
            "PROGRESS.md": "# progress\n" * 50,
            "TASK_QUEUE.md": "# queue\n" * 50,
        })
        pack = relevance_pack.build_pack(
            task_text="## Task\nUpdate src/component.tsx to handle X.\n",
            task_id="NC-TEST-BK",
            phase="impl_review",
            project_path=str(proj),
            changed_files=["src/component.tsx", "PROGRESS.md", "TASK_QUEUE.md"],
        )
        by_path = _entries_by_path(pack["meta"])

        _check("src/component.tsx is rank 1 (non-bookkeeping diff)",
               by_path.get("src/component.tsx", {}).get("rank") == 1,
               str(by_path.get("src/component.tsx")))

        # Bookkeeping files either demoted (rank 99) or fully evicted by budget —
        # either outcome satisfies the intent.
        for bk in ("PROGRESS.md", "TASK_QUEUE.md"):
            if bk in by_path:
                _check(f"{bk} demoted to rank 99",
                       by_path[bk]["rank"] == 99,
                       f"got rank={by_path[bk]['rank']}")
                _check(f"{bk} reason mentions bookkeeping",
                       any("bookkeeping" in r for r in by_path[bk]["reasons"]),
                       str(by_path[bk]["reasons"]))

        paths_in_order = [e["file"] for e in pack["meta"]["entries"]]
        if "PROGRESS.md" in paths_in_order:
            _check("src/component.tsx ordered before PROGRESS.md",
                   paths_in_order.index("src/component.tsx")
                   < paths_in_order.index("PROGRESS.md"))


def test_per_file_cap_prevents_single_file_domination() -> None:
    """PER_FILE_EXCERPT_CAP now 2500 — three larger files should all fit
    rather than one 5KB entry hogging the 7KB section budget.
    Regression for NC-390 where en.json (5072B) evicted advisor/page.tsx
    and test-chat-panel.tsx before they were reached.
    """
    print("\n[test] per-file cap lets 3 decisive files coexist")
    big = "// filler keyword update handle component dismiss line\n" * 120
    with tempfile.TemporaryDirectory() as tmp:
        proj = _make_project(Path(tmp), {
            "a.ts": big, "b.ts": big, "c.ts": big,
        })
        pack = relevance_pack.build_pack(
            task_text=(
                "## Task\nUpdate handle component dismiss.\n"
                "## Files\n- a.ts\n- b.ts\n- c.ts\n"
            ),
            task_id="NC-TEST-CAP",
            phase="plan_audit",
            project_path=str(proj),
        )
        by_path = _entries_by_path(pack["meta"])
        for name in ("a.ts", "b.ts", "c.ts"):
            _check(f"{name} appears in pack (not evicted)",
                   name in by_path,
                   f"entries={list(by_path.keys())}")
        for e in pack["meta"]["entries"]:
            _check(f"{e['file']} excerpt respects 2500B cap (+header overhead)",
                   e["bytes"] < 3000,
                   f"got {e['bytes']}B")


def test_shipped_check_same_selector_as_plan_audit() -> None:
    """F5: shipped_check uses the same candidate selector as plan_audit.
    ## Files entries → rank 1, inline refs → rank 2, etc. No diff signal."""
    print("\n[test] shipped_check reuses plan_audit selector surface")
    with tempfile.TemporaryDirectory() as tmp:
        proj = _make_project(Path(tmp), {
            "src/foo.ts": "export const foo = 1;\n",
            "src/bar.ts": "export const bar = 2;\n",
        })
        task = """# NC-SHIP

## Files
- src/foo.ts

## Acceptance Criteria
- foo and bar both exported

Also see src/bar.ts:10 for the existing bar binding.
"""
        out = relevance_pack.build_pack(
            task_text=task, task_id="NC-S1", phase="shipped_check",
            project_path=str(proj),
        )
        entries = _entries_by_path(out["meta"])
        _check("src/foo.ts rank 1 (named in ## Files)",
               entries.get("src/foo.ts", {}).get("rank") == 1,
               str(entries.get("src/foo.ts")))
        _check("src/bar.ts rank 2 (inline ref)",
               entries.get("src/bar.ts", {}).get("rank") == 2,
               str(entries.get("src/bar.ts")))
        _check("phase label reads 'shipped check' in pack header",
               "shipped check" in out["text"].splitlines()[0].lower(),
               out["text"].splitlines()[0])


def test_shipped_check_omits_prior_findings_and_audit_patterns() -> None:
    """F5: shipped_check drops prior-findings + audit-patterns sections.
    Reviewer complaints and style conventions are noise for the existence
    question. Keeps the pack lean and focused on 'is this work present'."""
    print("\n[test] shipped_check pack omits prior-findings + audit-patterns")
    with tempfile.TemporaryDirectory() as tmp:
        proj = _make_project(Path(tmp), {"src/a.ts": "// a\n"})
        # Seed a prior finding that would be included for plan_audit.
        state = Path(tmp) / "state"
        sessions = state / "sessions"
        sessions.mkdir(parents=True)
        s = sessions / "sess-prior"
        s.mkdir()
        (s / "journal.jsonl").write_text(json.dumps({
            "event": "audit_complete",
            "project": proj.name,
            "task_id": "NC-OLD",
            "blocking_issues": [{"required_change": "LEAK_MARKER_X"}],
        }) + "\n")

        out = relevance_pack.build_pack(
            task_text="## Files\n- src/a.ts\n",
            task_id="NC-S2", phase="shipped_check",
            project_path=str(proj),
            state_dir=str(state),
        )
        _check("no 'Prior reviewer findings' section header",
               "Prior reviewer findings" not in out["text"],
               out["text"][-400:])
        _check("no 'Area memory' section header",
               "Area memory" not in out["text"],
               out["text"][-400:])
        _check("prior finding leak marker absent",
               "LEAK_MARKER_X" not in out["text"],
               out["text"][-400:])
        _check("shipped-specific closing note present",
               "SHIPPED only when" in out["text"]
               or "functional intent is already present" in out["text"],
               out["text"][-400:])


def test_shipped_check_keeps_task_and_excerpts_and_git_history() -> None:
    """F5: shipped_check still includes Task spec + Likely touched files +
    Recent commits. Those are the load-bearing signals for existence."""
    print("\n[test] shipped_check keeps Task + file excerpts + git-history sections")
    with tempfile.TemporaryDirectory() as tmp:
        proj = _make_project(Path(tmp), {"src/a.ts": "// SHIP_CANARY content\n"})
        # Init git so the per-file log produces output.
        subprocess.run(["git", "init", "-q"], cwd=proj, check=True)
        subprocess.run(["git", "config", "user.email", "t@t"], cwd=proj, check=True)
        subprocess.run(["git", "config", "user.name", "t"], cwd=proj, check=True)
        subprocess.run(["git", "add", "-A"], cwd=proj, check=True)
        subprocess.run(["git", "commit", "-qm", "SHIP_COMMIT_MSG"], cwd=proj, check=True)

        out = relevance_pack.build_pack(
            task_text="## Files\n- src/a.ts\n\n## AC\n- SHIP_CANARY exists",
            task_id="NC-S3", phase="shipped_check",
            project_path=str(proj),
        )
        text = out["text"]
        _check("Task section header present", "## Task" in text)
        _check("Likely touched files section present",
               "## Likely touched files" in text)
        _check("Recent commits section present",
               "## Recent commits in this area" in text)
        _check("file excerpt visible in pack", "SHIP_CANARY" in text)
        _check("commit subject visible in pack",
               "SHIP_COMMIT_MSG" in text, text[-600:])


def test_shipped_check_sees_commits_on_other_branches() -> None:
    """F5 P1: shipped_check per-file history must use --all so a feature
    that landed on a side branch (or before merge-base) is still visible.
    Regression for Codex audit finding: old _collect_git_history was
    current-branch-only `git log -5`, which was exactly the blind spot
    F5 exists to cover."""
    print("\n[test] shipped_check: commit on side branch is visible (--all)")
    with tempfile.TemporaryDirectory() as tmp:
        proj = _make_project(Path(tmp), {"src/a.ts": "// initial\n"})
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=proj, check=True)
        subprocess.run(["git", "config", "user.email", "t@t"], cwd=proj, check=True)
        subprocess.run(["git", "config", "user.name", "t"], cwd=proj, check=True)
        subprocess.run(["git", "add", "-A"], cwd=proj, check=True)
        subprocess.run(["git", "commit", "-qm", "MAIN_BASE"], cwd=proj, check=True)
        # Land the "feature" on a side branch that main never merges.
        subprocess.run(["git", "checkout", "-q", "-b", "feat/sidebranch"],
                       cwd=proj, check=True)
        (proj / "src" / "a.ts").write_text("// updated on side branch\n")
        subprocess.run(["git", "add", "-A"], cwd=proj, check=True)
        subprocess.run(["git", "commit", "-qm",
                        "SIDEBRANCH_CANARY_SUBJECT"], cwd=proj, check=True)
        # Switch back so "current branch" does NOT contain the canary commit.
        subprocess.run(["git", "checkout", "-q", "main"], cwd=proj, check=True)

        out = relevance_pack.build_pack(
            task_text="## Files\n- src/a.ts\n\n## AC\n- update exists",
            task_id="NC-S-SIDE", phase="shipped_check",
            project_path=str(proj),
        )
        _check("side-branch commit subject reaches shipped_check pack",
               "SIDEBRANCH_CANARY_SUBJECT" in out["text"],
               out["text"][-800:])

        # And plan_audit (narrower default) should NOT see it — that's the
        # whole reason we pass all_branches=True only for shipped_check.
        out_plan = relevance_pack.build_pack(
            task_text="## Files\n- src/a.ts\n\n## AC\n- update exists",
            task_id="NC-S-SIDE", phase="plan_audit",
            project_path=str(proj),
        )
        _check("plan_audit keeps current-branch-only history (no leak)",
               "SIDEBRANCH_CANARY_SUBJECT" not in out_plan["text"],
               out_plan["text"][-400:])


def test_shipped_check_intent_commits_section() -> None:
    """F5 P1: shipped_check pack includes a 'Recent commits matching task
    intent' section that surfaces commits on any branch whose subject
    overlaps the task's keyword set — even when those commits don't touch
    any of the selector-picked files."""
    print("\n[test] shipped_check: intent-keyword commit surfaces in new section")
    with tempfile.TemporaryDirectory() as tmp:
        # Selector-picked file is src/unrelated.ts. The 'shipped' evidence
        # lives on a *different* file that the selector won't pick, but the
        # commit subject overlaps the task's AC keyword set.
        proj = _make_project(Path(tmp), {
            "src/unrelated.ts": "// placeholder\n",
            "src/shipped_feature.ts": "// implementation body\n",
        })
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=proj, check=True)
        subprocess.run(["git", "config", "user.email", "t@t"], cwd=proj, check=True)
        subprocess.run(["git", "config", "user.name", "t"], cwd=proj, check=True)
        subprocess.run(["git", "add", "-A"], cwd=proj, check=True)
        # Keyword 'tenant_isolation' will appear in task AC below.
        subprocess.run(["git", "commit", "-qm",
                        "feat: enforce tenant_isolation on leads endpoint"],
                       cwd=proj, check=True)

        out = relevance_pack.build_pack(
            task_text=(
                "# NC-INTENT\n\n"
                "## Files\n- src/unrelated.ts\n\n"
                "## Acceptance Criteria\n"
                "- tenant_isolation is enforced on the leads endpoint\n"
            ),
            task_id="NC-INTENT", phase="shipped_check",
            project_path=str(proj),
        )
        text = out["text"]
        _check("intent-commits section header present",
               "## Recent commits matching task intent" in text,
               text[-600:])
        _check("keyword-matching commit subject appears in section",
               "tenant_isolation" in text and "leads endpoint" in text,
               text[-600:])
        _check("matches-annotation shown next to commit",
               "[matches:" in text, text[-600:])

        # plan_audit and impl_review must NOT grow this section.
        out_plan = relevance_pack.build_pack(
            task_text=(
                "## Files\n- src/unrelated.ts\n\n"
                "## AC\n- tenant_isolation enforced\n"
            ),
            task_id="NC-INTENT", phase="plan_audit",
            project_path=str(proj),
        )
        _check("plan_audit does NOT include intent-commits section",
               "Recent commits matching task intent" not in out_plan["text"],
               out_plan["text"][-300:])


def test_truncate_to_fit_preserves_last_entry() -> None:
    """When an entry would exceed remaining budget, truncate to fit rather
    than drop — a half-file of a decisive .tsx beats a full file of noise.
    """
    print("\n[test] truncate-to-fit preserves last entry instead of all-or-nothing evict")
    big = "// filler keyword update handle component dismiss line\n" * 120
    with tempfile.TemporaryDirectory() as tmp:
        proj = _make_project(Path(tmp), {
            "a.ts": big, "b.ts": big, "c.ts": big, "d.ts": big,
        })
        pack = relevance_pack.build_pack(
            task_text=(
                "## Task\nUpdate handle component dismiss.\n"
                "## Files\n- a.ts\n- b.ts\n- c.ts\n- d.ts\n"
            ),
            task_id="NC-TEST-TRUNC",
            phase="plan_audit",
            project_path=str(proj),
        )
        _check("TRUNCATED marker present in pack body",
               "[TRUNCATED — pack budget]" in pack["text"],
               pack["text"][-300:] if "TRUNCATED" not in pack["text"] else "")


def main() -> int:
    test_task_files_rank1_plan_audit()
    test_inline_ref_picked_up()
    test_duplicate_reasons_collapse()
    test_impl_review_prefers_diff_over_keyword()
    test_excluded_dirs_filtered()
    test_missing_audit_patterns_silent()
    test_oversized_file_summarized()
    test_artifact_write_and_attempt_suffix()
    test_prior_findings_scan_scope()
    test_current_session_excluded_from_prior_findings()
    test_review_impl_picks_up_untracked_files()
    test_budget_sub_section_isolated()
    test_bookkeeping_files_demoted_in_impl_review()
    test_per_file_cap_prevents_single_file_domination()
    test_shipped_check_same_selector_as_plan_audit()
    test_shipped_check_omits_prior_findings_and_audit_patterns()
    test_shipped_check_keeps_task_and_excerpts_and_git_history()
    test_shipped_check_sees_commits_on_other_branches()
    test_shipped_check_intent_commits_section()
    test_truncate_to_fit_preserves_last_entry()

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
