"""F1 — Relevance pack builder.

Assembles a deterministic context bundle before each plan audit or impl review.

Design points (see PLAN-phase-bcf.md §F1):
    • Phase-specific rank ordering — `impl_review` promotes git-diff files above
      keyword hits; `plan_audit` uses task-text signals only.
    • Sub-budgets per section so one signal cannot starve the others. Total
      default 15 KB; each section truncates itself rather than the whole pack.
    • Duplicate-reason collapse — same file included by multiple signals keeps
      the highest-priority rank and accumulates all reasons in the meta sidecar.
    • Explicit exclusions for vendor/build/state dirs; grep --exclude-dir flags
      mirror the same list so keyword discovery stays fast on large repos.
    • Prior reviewer findings come from `$STATE_DIR/sessions/*/journal.jsonl`,
      newest-first, hard-capped. Current-session findings are intentionally
      NOT included — they're already in the orchestrator's context; a fresh
      `call_codex.py` invocation would need explicit plumbing we don't do yet.

The public API is `build_pack(...)`; all other helpers are private.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, List, Optional, Tuple


# =============================================================================
# Tunables (bytes, counts)
# =============================================================================

# Per-section budgets — sum equals DEFAULT_TOTAL_BUDGET below. Each section
# truncates itself; overflow in one section does NOT crowd out other sections.
TASK_SPEC_BUDGET = 3000
FILE_EXCERPTS_BUDGET = 7000
GIT_HISTORY_BUDGET = 2000
PRIOR_FINDINGS_BUDGET = 2000
AUDIT_PATTERNS_BUDGET = 1000
DEFAULT_TOTAL_BUDGET = (
    TASK_SPEC_BUDGET
    + FILE_EXCERPTS_BUDGET
    + GIT_HISTORY_BUDGET
    + PRIOR_FINDINGS_BUDGET
    + AUDIT_PATTERNS_BUDGET
)

# Per-file excerpt cap. Files above this are summarized (head 100 lines +
# sentinel + tail 50 lines).
PER_FILE_EXCERPT_CAP = 5000

# Keyword discovery caps — keep grep bounded on large repos.
MAX_KEYWORDS = 20
MIN_KEYWORD_LEN = 4
KEYWORD_HIT_CAP = 8

# Prior-findings scan caps.
PRIOR_SESSIONS_SCANNED = 5
PRIOR_FINDINGS_KEPT = 10


# =============================================================================
# Exclusions & readable-file allowlist
# =============================================================================

# Any path containing one of these parts is dropped. Mirrored in
# `_keyword_hits()` as grep --exclude-dir flags for speed.
EXCLUDED_DIRS = {
    "node_modules",
    ".next",
    "dist",
    "build",
    ".turbo",
    "coverage",
    ".git",
    ".nightcrawler",
    "state",
    "artifacts",
    "__pycache__",
    ".venv",
    ".cache",
    "out",
    ".vercel",
}

EXCLUDED_SUFFIXES = (
    ".lock",
    ".lockb",
    ".pyc",
    ".log",
    ".map",
    ".min.js",
    ".min.css",
)

EXCLUDED_NAMES = {
    "pnpm-lock.yaml",
    "yarn.lock",
    "package-lock.json",
    "Cargo.lock",
    "poetry.lock",
    "Pipfile.lock",
    "uv.lock",
    "composer.lock",
    "Gemfile.lock",
}

# Extensions we treat as readable text. Non-matching files are filtered out of
# keyword results (binary/image/archive noise).
READABLE_EXTS = {
    ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs",
    ".py", ".sol", ".rs", ".go", ".rb", ".php",
    ".java", ".kt", ".swift", ".c", ".cc", ".cpp", ".h", ".hpp",
    ".sh", ".bash", ".zsh", ".fish",
    ".md", ".mdx", ".txt", ".rst", ".adoc",
    ".yaml", ".yml", ".toml", ".json", ".jsonc",
    ".sql", ".prisma", ".graphql", ".gql",
    ".css", ".scss", ".sass", ".less",
    ".html", ".xml", ".svelte", ".vue",
    ".ex", ".exs", ".erl",
    ".env.example",
}

# Extensionless filenames worth reading.
READABLE_NAMES = {
    "Makefile",
    "Dockerfile",
    "CHANGELOG",
    "README",
    "LICENSE",
}

# Stopwords filtered from keyword grep candidates.
STOPWORDS = {
    "the", "this", "that", "with", "from", "when", "then", "will", "shall",
    "should", "must", "have", "been", "were", "what", "into", "onto", "over",
    "under", "task", "plan", "need", "does", "also", "using", "make", "made",
    "just", "very", "some", "only", "your", "their", "there", "these", "those",
    "each", "other", "such", "than", "more", "most", "many", "much", "work",
    "test", "tests", "code", "file", "files", "impl", "implementation",
    "todo", "true", "false", "null", "none", "lines", "line", "change",
    "changes", "project", "repo", "would", "could", "about", "after", "before",
    "where", "which", "while", "during", "because",
}


# =============================================================================
# Data classes
# =============================================================================

@dataclass
class PackEntry:
    path: str                                     # relative to project root
    reasons: List[str] = field(default_factory=list)
    rank: int = 99                                # lower = higher priority
    bytes: int = 0                                # size of excerpt embedded
    excerpt: str = ""
    summarized: bool = False                      # head+tail instead of whole file


@dataclass
class ExcludedCandidate:
    path: str
    reason: str


# =============================================================================
# Path / file helpers
# =============================================================================

def _is_excluded(rel: Path) -> bool:
    """True if the path lives inside a vendor/build/state dir or is a lock
    file. Symmetric with the grep --exclude-dir list."""
    for part in rel.parts:
        if part in EXCLUDED_DIRS:
            return True
    name = rel.name
    if name in EXCLUDED_NAMES:
        return True
    for suf in EXCLUDED_SUFFIXES:
        if name.endswith(suf):
            return True
    # Secondary lock-file pattern: *lock.json (e.g. package-lock.json already
    # hit by EXCLUDED_NAMES; leave this as a belt-and-suspenders check).
    if name.endswith("lock.json"):
        return True
    return False


def _is_readable(rel: Path) -> bool:
    if rel.suffix.lower() in READABLE_EXTS:
        return True
    if rel.name in READABLE_NAMES:
        return True
    return False


def _normalize_rel(project: Path, rel: str) -> Optional[str]:
    """Return the path relative to project, or None if it escapes the root or
    doesn't exist. Resolves symlinks so /foo/bar/../baz doesn't confuse us."""
    candidate = (project / rel).resolve(strict=False)
    try:
        resolved_rel = candidate.relative_to(project.resolve(strict=False))
    except ValueError:
        return None
    if not candidate.exists() or candidate.is_dir():
        return None
    return str(resolved_rel)


# =============================================================================
# Signal extractors
# =============================================================================

_SECTION_RE = re.compile(r"^##\s+(.+?)\s*$")


def _parse_task_sections(task_text: str) -> dict:
    """Split task text by `##` level-2 sections."""
    sections: dict = {}
    current = "_preamble"
    buf: List[str] = []
    for line in task_text.splitlines():
        m = _SECTION_RE.match(line)
        if m:
            sections[current] = "\n".join(buf).strip()
            current = m.group(1).strip().lower()
            buf = []
        else:
            buf.append(line)
    sections[current] = "\n".join(buf).strip()
    return sections


def _find_task_files(task_text: str, project: Path) -> List[str]:
    """Files named in `## Files` / `## Touched Files` / `## Scope` sections."""
    sections = _parse_task_sections(task_text)
    keys = [k for k in sections
            if any(tok in k for tok in ("files", "scope", "touched"))]
    out: List[str] = []
    seen: set = set()
    for k in keys:
        for line in sections[k].splitlines():
            s = line.strip().lstrip("-*+ ").strip()
            if not s:
                continue
            # First whitespace-chunk, strip trailing punctuation and backticks.
            first = s.split()[0].strip("`.,:;()[]{}")
            if not first:
                continue
            # Must look like a path (has / or an extension).
            if "/" not in first and "." not in first:
                continue
            norm = _normalize_rel(project, first)
            if norm and norm not in seen:
                seen.add(norm)
                out.append(norm)
    return out


# Inline file references: "src/db/leads.ts:47" or "apps/web/app/page.tsx".
_INLINE_REF_RE = re.compile(
    r"(?<![A-Za-z0-9_/])([A-Za-z0-9_.\-]+(?:/[A-Za-z0-9_.\-]+)+\.[A-Za-z0-9]+)"
    r"(?::\d+)?"
)


def _find_inline_refs(task_text: str, project: Path) -> List[str]:
    out: List[str] = []
    seen: set = set()
    for m in _INLINE_REF_RE.finditer(task_text):
        norm = _normalize_rel(project, m.group(1))
        if norm and norm not in seen:
            seen.add(norm)
            out.append(norm)
    return out


# Spec-doc names we always look up if mentioned.
_SPEC_DOC_NAMES = re.compile(
    r"\b(RULES\.md|SPEC\.md|README\.md|ARCHITECTURE\.md|PROGRESS\.md|"
    r"TASK_QUEUE\.md|CHANGELOG\.md)\b"
)
_PLAN_DOC_RE = re.compile(r"\b(PLAN-[A-Za-z0-9_\-]+\.md)\b")


def _find_spec_docs(task_text: str, project: Path) -> List[str]:
    candidates: set = set()
    for m in _SPEC_DOC_NAMES.finditer(task_text):
        candidates.add(m.group(1))
    for m in _PLAN_DOC_RE.finditer(task_text):
        candidates.add(m.group(1))
    out: List[str] = []
    for c in sorted(candidates):
        norm = _normalize_rel(project, c)
        if norm:
            out.append(norm)
    return out


def _extract_keywords(task_text: str) -> List[str]:
    """Tokens from Acceptance / AC / Requirements sections; fall back to full
    task text. Min length, stopword filtering, hard cap."""
    sections = _parse_task_sections(task_text)
    corpus_parts: List[str] = []
    for k, v in sections.items():
        if any(tok in k for tok in ("acceptance", "criteria", "requirements")):
            corpus_parts.append(v)
        elif k.strip() == "ac":
            corpus_parts.append(v)
    corpus = "\n".join(corpus_parts) if corpus_parts else task_text

    pattern = r"[A-Za-z][A-Za-z0-9_]{%d,}" % (MIN_KEYWORD_LEN - 1)
    out: List[str] = []
    seen: set = set()
    for tok in re.findall(pattern, corpus):
        low = tok.lower()
        if low in STOPWORDS or low in seen:
            continue
        seen.add(low)
        out.append(tok)
        if len(out) >= MAX_KEYWORDS:
            break
    return out


def _keyword_hits(keywords: List[str], project: Path) -> List[str]:
    """`grep -rlE` for any keyword. Exclusion dirs mirror EXCLUDED_DIRS so the
    walk stays fast on large repos."""
    if not keywords:
        return []
    pattern = "|".join(re.escape(k) for k in keywords)
    cmd = ["grep", "-rlE", "--binary-files=without-match"]
    for d in EXCLUDED_DIRS:
        cmd.append(f"--exclude-dir={d}")
    cmd += [pattern, "."]
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(project),
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return []

    out: List[str] = []
    seen: set = set()
    for line in proc.stdout.splitlines():
        rel = line.lstrip("./")
        if not rel:
            continue
        p = Path(rel)
        if _is_excluded(p):
            continue
        if not _is_readable(p):
            continue
        if rel in seen:
            continue
        seen.add(rel)
        out.append(rel)
        if len(out) >= KEYWORD_HIT_CAP:
            break
    return out


# =============================================================================
# Excerpt / git / prior-findings / area-memory
# =============================================================================

def _read_excerpt(project: Path, rel: str,
                  per_file_budget: int) -> Tuple[str, int, bool]:
    """Return (excerpt_text, byte_count, summarized). Files above budget are
    rendered as head 100 lines + sentinel + tail 50 lines, then hard-capped."""
    full = (project / rel).read_text(errors="replace")
    if len(full) <= per_file_budget:
        return full, len(full), False
    lines = full.splitlines()
    head = "\n".join(lines[:100])
    tail = "\n".join(lines[-50:]) if len(lines) > 150 else ""
    sentinel = (
        f"\n\n... [summarized: full file is {len(full)} bytes; "
        "showing head (100) + tail (50) lines]\n\n"
    )
    summary = head + sentinel + tail
    if len(summary) > per_file_budget:
        summary = summary[:per_file_budget] + "\n... [TRUNCATED]"
    return summary, len(summary), True


def _collect_git_history(project: Path, files: List[str], budget: int) -> str:
    """`git log -5 --oneline -- <file>` for each kept file, aggregated under
    the section budget. Stops cleanly when budget is exhausted."""
    if not files or budget <= 0:
        return ""
    out_parts: List[str] = []
    used = 0
    for f in files:
        try:
            proc = subprocess.run(
                ["git", "log", "-5", "--oneline", "--", f],
                cwd=str(project),
                capture_output=True,
                text=True,
                timeout=5,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue
        log_text = proc.stdout.strip()
        if not log_text:
            continue
        block = f"{f}:\n{log_text}\n"
        if used + len(block) > budget:
            remaining = budget - used
            if remaining > 40:
                out_parts.append(
                    block[:remaining] + "\n... [git history truncated]"
                )
            break
        out_parts.append(block)
        used += len(block)
    return "\n".join(out_parts)


def _collect_prior_findings(state_dir: Optional[str],
                            project: Path,
                            budget: int,
                            *,
                            current_session_dir: Optional[str] = None) -> str:
    """Scan $STATE_DIR/sessions/*/journal.jsonl newest-first; extract
    audit/review events for this project with non-empty blocking_issues.

    The current session is skipped — its findings are written by the same
    orchestrator run and pulling them back into a later audit/review prompt
    would create self-referential context. `current_session_dir` is matched
    by resolved path, not basename, so non-standard layouts still work.

    Hard-capped by PRIOR_SESSIONS_SCANNED and PRIOR_FINDINGS_KEPT.
    """
    if not state_dir or budget <= 0:
        return ""
    sessions_root = Path(state_dir) / "sessions"
    if not sessions_root.is_dir():
        return ""

    skip_path: Optional[Path] = None
    if current_session_dir:
        try:
            skip_path = Path(current_session_dir).resolve()
        except OSError:
            skip_path = None

    try:
        all_dirs = sorted(
            (d for d in sessions_root.iterdir() if d.is_dir()),
            key=lambda d: d.stat().st_mtime,
            reverse=True,
        )
    except OSError:
        return ""

    session_dirs: List[Path] = []
    for d in all_dirs:
        if skip_path is not None:
            try:
                if d.resolve() == skip_path:
                    continue
            except OSError:
                pass
        session_dirs.append(d)
        if len(session_dirs) >= PRIOR_SESSIONS_SCANNED:
            break

    proj_name = project.name
    findings: List[str] = []
    for d in session_dirs:
        jpath = d / "journal.jsonl"
        if not jpath.exists():
            continue
        try:
            raw = jpath.read_text(errors="replace")
        except OSError:
            continue
        for line in raw.splitlines():
            if not line.strip():
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            ev = obj.get("event", "")
            if ev not in ("audit_complete", "review_complete"):
                continue
            if obj.get("project") and obj["project"] != proj_name:
                continue
            bi = obj.get("blocking_issues")
            if not bi:
                continue
            tid = obj.get("task_id", "?")
            first_issue = bi[0] if isinstance(bi, list) and bi else bi
            findings.append(f"[{tid}] {ev}: {str(first_issue)[:300]}")
            if len(findings) >= PRIOR_FINDINGS_KEPT:
                break
        if len(findings) >= PRIOR_FINDINGS_KEPT:
            break

    if not findings:
        return ""
    joined = "\n".join(f"- {f}" for f in findings)
    if len(joined) > budget:
        joined = joined[:budget] + "\n... [prior findings truncated]"
    return joined


def _load_audit_patterns(project_name: str) -> Tuple[Optional[str], str]:
    """F4 dependency — graceful fallback when audit-patterns.md is absent.
    Returns (relative_path, content). Both empty/None when the file doesn't
    exist yet."""
    # relevance_pack.py lives at <repo>/scripts/lib/, repo root is parent².parent.
    repo_root = Path(__file__).resolve().parent.parent.parent
    candidate = repo_root / "config" / "projects" / project_name / "audit-patterns.md"
    if not candidate.exists():
        return None, ""
    text = candidate.read_text(errors="replace")
    return f"config/projects/{project_name}/audit-patterns.md", text


# =============================================================================
# Entry collapse
# =============================================================================

def _collapse_entries(raw: Iterable[Tuple[int, str, str]]) -> List[PackEntry]:
    """Merge duplicates. Same path keeps the smallest rank, accumulates all
    distinct reasons in insertion order, then sorted deterministically."""
    by_path: dict = {}
    for rank, rel, reason in raw:
        e = by_path.get(rel)
        if e is None:
            by_path[rel] = PackEntry(path=rel, reasons=[reason], rank=rank)
        else:
            if rank < e.rank:
                e.rank = rank
            if reason not in e.reasons:
                e.reasons.append(reason)
    return sorted(by_path.values(), key=lambda e: (e.rank, e.path))


# =============================================================================
# Public API
# =============================================================================

def build_pack(
    *,
    task_text: str,
    task_id: str,
    phase: str,
    project_path: str,
    state_dir: Optional[str] = None,
    artifact_dir: Optional[str] = None,
    changed_files: Optional[List[str]] = None,
    budget_bytes: int = DEFAULT_TOTAL_BUDGET,
    current_session_dir: Optional[str] = None,
) -> dict:
    """Assemble a relevance pack.

    Args:
        task_text: Full task spec body.
        task_id: e.g. "NC-042".
        phase: "plan_audit" or "impl_review".
        project_path: Absolute path to the user's project repo (camello, clout, ...).
        state_dir: STATE_DIR root for prior-findings scan. Optional.
        artifact_dir: If set, writes `<task_id>.<phase>.{txt,meta.json}` under it
            (with `.attemptN` suffix if the file already exists).
        changed_files: For `impl_review`, the `git diff --name-only` list.
        budget_bytes: Total soft budget (informational — sub-budgets are authoritative).

    Returns:
        {"text": str, "meta": dict, "artifacts": {"text_path", "meta_path"}}
    """
    if phase not in ("plan_audit", "impl_review"):
        raise ValueError(f"unknown phase: {phase}")

    project = Path(project_path).resolve() if project_path else Path.cwd()
    changed_files = changed_files or []

    rank_map: List[Tuple[int, str, str]] = []
    excluded: List[ExcludedCandidate] = []

    # ---- rank layout (phase-specific) ----
    if phase == "impl_review":
        # Changed files = strongest signal. Task/spec are secondary.
        diff_rank, task_rank, inline_rank, spec_rank, kw_rank = 1, 2, 3, 4, 5
    else:
        diff_rank = None  # unused
        task_rank, inline_rank, spec_rank, kw_rank = 1, 2, 3, 4

    # 1. git-diff files (review phase only)
    if phase == "impl_review":
        for f in changed_files:
            norm = _normalize_rel(project, f)
            if not norm:
                excluded.append(ExcludedCandidate(
                    f, "changed file missing or outside project root"))
                continue
            if _is_excluded(Path(norm)):
                excluded.append(ExcludedCandidate(
                    norm, "excluded by path rule (vendor/build/state)"))
                continue
            rank_map.append(
                (diff_rank, norm, "appears in git diff (changed file)")
            )

    # 2. ## Files / Scope sections
    for f in _find_task_files(task_text, project):
        if _is_excluded(Path(f)):
            excluded.append(ExcludedCandidate(f, "excluded by path rule"))
            continue
        rank_map.append(
            (task_rank, f, "named in task ## Files/Scope section")
        )

    # 3. inline path refs (foo/bar.ts:42)
    for f in _find_inline_refs(task_text, project):
        if _is_excluded(Path(f)):
            excluded.append(ExcludedCandidate(f, "excluded by path rule"))
            continue
        rank_map.append((inline_rank, f, "inline path reference in task body"))

    # 4. spec/doc filenames (PLAN-*.md, RULES.md, SPEC.md, ...)
    for f in _find_spec_docs(task_text, project):
        rank_map.append((spec_rank, f, "spec/doc referenced by task"))

    # 5. keyword-grep hits
    keywords = _extract_keywords(task_text)
    for f in _keyword_hits(keywords, project):
        rank_map.append(
            (kw_rank, f, f"matched task keyword(s) (top {len(keywords)} terms)")
        )

    entries = _collapse_entries(rank_map)

    # ---- file-excerpt section (bounded by FILE_EXCERPTS_BUDGET) ----
    excerpt_parts: List[str] = []
    excerpts_used = 0
    for e in entries:
        try:
            excerpt, n, summarized = _read_excerpt(
                project, e.path, PER_FILE_EXCERPT_CAP
            )
        except (FileNotFoundError, OSError) as exc:
            excluded.append(ExcludedCandidate(e.path, f"read failed: {exc}"))
            continue
        header = (
            f"--- {e.path} "
            f"({'summarized, ' if summarized else ''}rank={e.rank}) ---\n"
        )
        block = header + excerpt + "\n"
        if excerpts_used + len(block) > FILE_EXCERPTS_BUDGET:
            excluded.append(ExcludedCandidate(
                e.path,
                f"skipped: file-excerpts budget exhausted "
                f"({excerpts_used}/{FILE_EXCERPTS_BUDGET} bytes)",
            ))
            continue
        excerpt_parts.append(block)
        e.bytes = len(block)
        e.excerpt = excerpt
        e.summarized = summarized
        excerpts_used += len(block)

    excerpts_text = "\n".join(excerpt_parts)

    # ---- task/spec section ----
    task_section = task_text
    if len(task_section) > TASK_SPEC_BUDGET:
        task_section = task_section[:TASK_SPEC_BUDGET] + "\n... [task truncated]"

    # ---- git history (only for files that made it into excerpts) ----
    kept_files = [e.path for e in entries if e.bytes > 0]
    git_section = _collect_git_history(project, kept_files, GIT_HISTORY_BUDGET)

    # ---- prior findings (skip current session — see _collect_prior_findings) ----
    prior_section = _collect_prior_findings(
        state_dir, project, PRIOR_FINDINGS_BUDGET,
        current_session_dir=current_session_dir,
    )

    # ---- audit-patterns (F4 dependency, graceful fallback) ----
    patterns_rel, patterns_text = _load_audit_patterns(project.name)
    if patterns_text and len(patterns_text) > AUDIT_PATTERNS_BUDGET:
        patterns_text = (
            patterns_text[:AUDIT_PATTERNS_BUDGET]
            + "\n... [audit-patterns truncated]"
        )

    # ---- assemble ----
    phase_label = {
        "plan_audit": "plan audit",
        "impl_review": "impl review",
    }[phase]
    pieces = [
        f"RELEVANCE PACK for {task_id} ({phase_label})",
        "=" * 60,
        "",
        "## Task",
        task_section,
        "",
        "## Likely touched files",
        excerpts_text if excerpts_text else "(no files selected)",
        "",
        "## Recent commits in this area",
        git_section if git_section else "(no git history available)",
        "",
        "## Prior reviewer findings",
        prior_section if prior_section
        else "(no prior findings for this project in scanned sessions)",
        "",
        "## Area memory (audit-patterns.md)",
        patterns_text if patterns_text
        else "(no audit-patterns.md for this project yet — F4 not shipped)",
        "",
        "NOTE: Only comment on things supported by this pack — either by direct "
        "reference to a file/commit/prior-finding, or by a direct contradiction "
        "you can point to in the code. If you cannot ground a concern in the "
        "pack or in the code, it belongs in advisories[] at most.",
        "",
    ]
    text = "\n".join(pieces)

    # ---- meta sidecar ----
    meta_entries = []
    for e in entries:
        if e.bytes == 0:
            continue
        meta_entries.append({
            "file": e.path,
            "reasons": e.reasons,
            "rank": e.rank,
            "bytes": e.bytes,
            "summarized": e.summarized,
        })
    if patterns_rel:
        meta_entries.append({
            "file": patterns_rel,
            "reasons": ["always-included area memory"],
            "rank": 0,
            "bytes": len(patterns_text),
        })

    meta = {
        "task_id": task_id,
        "phase": phase,
        "project": project.name,
        "budget_bytes": budget_bytes,
        "total_bytes": len(text),
        "keywords_used": keywords,
        "entries": meta_entries,
        "excluded_candidates": [
            {"file": x.path, "reason": x.reason} for x in excluded
        ],
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

    # ---- write artifacts (if requested) ----
    text_path: Optional[str] = None
    meta_path: Optional[str] = None
    if artifact_dir:
        base = Path(artifact_dir)
        base.mkdir(parents=True, exist_ok=True)
        stem = f"{task_id}.{phase}"
        attempt = 0
        t = base / f"{stem}.txt"
        m = base / f"{stem}.meta.json"
        while (t.exists() or m.exists()) and attempt < 99:
            attempt += 1
            t = base / f"{stem}.attempt{attempt + 1}.txt"
            m = base / f"{stem}.attempt{attempt + 1}.meta.json"
        t.write_text(text)
        m.write_text(json.dumps(meta, indent=2))
        text_path = str(t)
        meta_path = str(m)

    return {
        "text": text,
        "meta": meta,
        "artifacts": {"text_path": text_path, "meta_path": meta_path},
    }
