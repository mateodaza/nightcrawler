#!/usr/bin/env python3
"""F6b.1: Complexity tier heuristic with prohibition-aware keyword extraction.

Classifies a task into TRIVIAL / STANDARD / RISKY based on cheap lexical
signals over the task body. Pure function — no LLM, no network, no filesystem
beyond stdin/stdout. The caller in nightcrawler.sh wires the result into
telemetry only (still observe-only as of F6b.1; stance/caps stay deferred to
F6b.2 once a Camello batch confirms the classifier is credible).

F6b.1 levers (added on top of F6a):
    1. Section-strip: drop content inside prohibition blocks
       (Non-goals / Do NOT / Don't / Never / Shall not) before keyword
       and file derivation. Prohibition mentions are negative-space and
       must not inflate signals (NC-402, NC-405 failure shape).
    2. Negation window: ignore keyword matches preceded within 5 same-line
       tokens by a negation word (no/not/without/never/nor/cannot/n't).
       Catches incidental denials like "no mutation, schema, or API change"
       (NC-404 shape).
    3. RISKY gate: requires either >=2 distinct keywords OR >=1 keyword
       paired with multi-file scope (>1 listed file). A solo benign keyword
       (e.g. "delete" in a UI button-reorder task) demotes to STANDARD
       rather than RISKY (NC-403/NC-399 shape).

Heuristic order:
    - >=2 distinct RISKY keywords  -> RISKY
    - >=1 RISKY keyword + files>1  -> RISKY
    - >=1 RISKY keyword (else)     -> STANDARD  (caution preserved)
    - ac<=2 AND files<=1           -> TRIVIAL
    - else                         -> STANDARD

AC counting: bullets inside a section whose header matches
"Acceptance" / "Done when" / "Criteria" (case-insensitive). Falls back to
total top-level bullet count if no such section is found. AC counts use the
ORIGINAL body (acceptance bullets are never inside a prohibition block).

File counting: distinct file paths matched by FILE_PATTERN over the
prohibition-stripped body (so files mentioned only inside Non-goals
do not inflate scope).

Output contract (JSON, single line, on stdout):
    {"tier": "TRIVIAL" | "STANDARD" | "RISKY",
     "signals": {
         "ac_count": int,
         "listed_files": int,
         "keywords": [str, ...],         # final post-filter
         "keywords_raw": [str, ...],     # all matches before filters
         "branch": str}}                 # which decision rule fired

`keywords_raw == keywords` means filters did not fire. When they differ,
the journal preserves both lists so we can post-hoc check whether the new
levers are working as intended.

F6b.2a: the `branch` field names the specific rule that decided the tier
(one of: "ge_2_keywords", "kw_plus_multifile", "solo_kw_demote",
"small_trivial", "default_standard"). The tier-check dry-run wrapper uses
this to show the operator *why* a task was classified the way it was —
particularly useful for spotting whether the 1-kw + files>1 branch (the
un-exercised one in the NC-408..412 observation batch) fires sensibly
before F6b.2b caps become behavior-affecting.

Callers: scripts/nightcrawler.sh::derive_complexity_tier (subprocess),
         scripts/tier-check.sh (F6b.2a dry-run wrapper).
"""
from __future__ import annotations

import json
import re
import sys
from typing import Dict, List, Tuple

RISKY_KEYWORDS: Tuple[str, ...] = (
    "migration",
    "schema",
    "auth",
    "crypto",
    "delete",
    "drop",
)

FILE_PATTERN = re.compile(
    r"[A-Za-z0-9_./-]+\.(?:ts|tsx|js|jsx|mjs|cjs|py|sol|go|rs|rb|java|kt|swift|sql)"
)
AC_HEADER = re.compile(r"^#{1,6}\s*(?:acceptance|done when|criteria)", re.IGNORECASE)
ANY_HEADER = re.compile(r"^#{1,6}\s")
BULLET = re.compile(r"^\s{0,3}[-*]\s")

# Lever 1: prohibition-block detection.
#
# A prohibition block starts at a line that introduces a "what NOT to do"
# section — either as a markdown header or a bolded section prefix:
#   "**Non-goals**", "**Non-goals (do NOT do):**", "## Non-goals",
#   "**Do NOT**", "**Don't**", "**Never**", "**Shall not**"
# It ends at the next markdown header, the next bolded section prefix
# (e.g. "**Files:**", "**Done when:**", "**Acceptance:**"), or a horizontal rule.
PROHIBITION_START = re.compile(
    r"^\s*(?:[-*]\s+)?"                                    # optional bullet
    r"(?:\*{2}|#{1,6}\s*)"                                 # bold-open or md header
    r"\s*(?:non[\s-]*goals?|do\s*not|don'?t|never|shall\s*not)"
    r"\b",
    re.IGNORECASE,
)
SECTION_BREAK = re.compile(
    r"^(?:"
    r"#{1,6}\s"                                            # markdown header
    r"|\*{2}[A-Z][^*]*\*{2}\s*:?\s*$"                      # **Bold heading[:]**
    r"|---+\s*$"                                           # horizontal rule
    r")"
)

# Lever 2: negation window.
NEGATION_TOKENS = frozenset({"no", "not", "without", "never", "nor", "cannot", "cant"})
NEGATION_WINDOW = 5  # tokens preceding a keyword on the same line


def strip_prohibition_blocks(body: str) -> str:
    """Replace lines inside any prohibition block with empty strings.

    Block start: a line matching PROHIBITION_START.
    Block end:   the first subsequent line matching SECTION_BREAK (and that
                 line itself is preserved unless it ALSO opens a new
                 prohibition block, in which case we stay in strip mode).
    Lines inside the block (including the start line) are replaced with "".
    Empty replacement preserves line numbering, which keeps AC counting
    happy (though AC uses the original body anyway — defensive).

    Idempotent: trailing-newline shape is preserved so repeated application
    is a fixed point.
    """
    out: List[str] = []
    in_block = False
    # Use split("\n"), not splitlines(): split preserves trailing empty
    # elements so join is a perfect round-trip, which is what makes the
    # transform idempotent.
    for line in body.split("\n"):
        if in_block:
            if SECTION_BREAK.match(line):
                if PROHIBITION_START.match(line):
                    out.append("")
                    continue
                in_block = False
                out.append(line)
                continue
            out.append("")
            continue
        if PROHIBITION_START.match(line):
            in_block = True
            out.append("")
            continue
        out.append(line)
    return "\n".join(out)


def count_ac_bullets(body: str) -> int:
    """Bullets inside an Acceptance-ish section, else total bullets.

    Uses the ORIGINAL body — Acceptance is never inside a prohibition block.
    """
    in_ac = False
    count = 0
    for line in body.splitlines():
        if AC_HEADER.match(line):
            in_ac = True
            continue
        if in_ac and ANY_HEADER.match(line):
            in_ac = False
            continue
        if in_ac and BULLET.match(line):
            count += 1
    if count > 0:
        return count
    return sum(1 for line in body.splitlines() if BULLET.match(line))


def count_listed_files(body: str) -> int:
    """Distinct file-path matches across the (already-filtered) body."""
    return len({m.group(0) for m in FILE_PATTERN.finditer(body)})


def _is_negated(preceding_segment: str) -> bool:
    """True if any of the last NEGATION_WINDOW tokens is a negation word.

    Tokenizes alphabetic + apostrophe sequences only. Catches:
      - bare negations: no, not, never, without, nor, cannot
      - clitics: don't, doesn't, won't, can't  -> token contains "n't"
    """
    tokens = re.findall(r"[a-z']+", preceding_segment.lower())
    window = tokens[-NEGATION_WINDOW:]
    for tok in window:
        if tok in NEGATION_TOKENS:
            return True
        if "n't" in tok:
            return True
    return False


def find_keywords_filtered(body: str) -> Tuple[List[str], List[str]]:
    """Apply negation window. Returns (final_kws, raw_kws), both in canonical
    order. A keyword is RETAINED if at least one occurrence is non-negated.
    A keyword is DROPPED only when ALL its occurrences are negated."""
    raw_found = set()
    final_found = set()
    for kw in RISKY_KEYWORDS:
        pat = re.compile(rf"\b{re.escape(kw)}\b", re.IGNORECASE)
        kept = False
        any_match = False
        for m in pat.finditer(body):
            any_match = True
            line_start = body.rfind("\n", 0, m.start()) + 1
            preceding = body[line_start:m.start()]
            if not _is_negated(preceding):
                kept = True
                break  # one un-negated mention is enough
        if any_match:
            raw_found.add(kw)
        if kept:
            final_found.add(kw)
    ordered_final = [k for k in RISKY_KEYWORDS if k in final_found]
    ordered_raw = [k for k in RISKY_KEYWORDS if k in raw_found]
    return ordered_final, ordered_raw


def derive_tier(body: str) -> Tuple[str, Dict]:
    filtered_body = strip_prohibition_blocks(body)
    ac = count_ac_bullets(body)
    files = count_listed_files(filtered_body)
    # `keywords_raw` tracks EVERY whole-word keyword hit in the original body,
    # regardless of section-strip or negation filtering. If this differs from
    # `keywords`, at least one of the two filters fired — useful diagnostic
    # signal in journal post-mortems.
    _, kws_raw = find_keywords_filtered(body)
    kws, _ = find_keywords_filtered(filtered_body)

    # Decision order matters: check the strongest RISKY signal first, then
    # the file-scoped RISKY gate, then solo-kw demote, then TRIVIAL shape,
    # else STANDARD by exclusion. The `branch` label names the rule that
    # fired so the dry-run wrapper and the journal can tell operators why.
    if len(kws) >= 2:
        tier = "RISKY"
        branch = "ge_2_keywords"
    elif len(kws) >= 1 and files > 1:
        tier = "RISKY"
        branch = "kw_plus_multifile"
    elif len(kws) >= 1:
        # Single benign-looking keyword in a small task — caution preserved
        # (don't flatten to TRIVIAL) but no RISKY shouting.
        tier = "STANDARD"
        branch = "solo_kw_demote"
    elif ac <= 2 and files <= 1:
        tier = "TRIVIAL"
        branch = "small_trivial"
    else:
        tier = "STANDARD"
        branch = "default_standard"

    signals = {
        "ac_count": ac,
        "listed_files": files,
        "keywords": kws,
        "keywords_raw": kws_raw,
        "branch": branch,
    }
    return tier, signals


def main() -> int:
    body = sys.stdin.read()
    tier, signals = derive_tier(body)
    json.dump({"tier": tier, "signals": signals}, sys.stdout, separators=(",", ":"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
