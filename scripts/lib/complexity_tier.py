#!/usr/bin/env python3
"""F6a: Complexity tier heuristic (observe-only).

Classifies a task into TRIVIAL / STANDARD / RISKY based on cheap
lexical signals over the task body. Pure function — no LLM, no network,
no filesystem beyond stdin/stdout. The caller in nightcrawler.sh wires
the result into telemetry only (see F6a in PLAN-phase-bcf.md).

Heuristic (per PLAN-phase-bcf.md F6):
    - Any RISKY-keyword whole-word hit -> RISKY.
      Keywords: migration, schema, auth, crypto, delete, drop.
    - Else ac_count <= 2 AND listed_files <= 1 -> TRIVIAL.
    - Else STANDARD.

AC counting: bullets inside a section whose header matches
"Acceptance" / "Done when" / "Criteria" (case-insensitive). Falls back
to total top-level bullet count if no such section is found — some
task specs list their AC as plain bullets under the main body.

File counting: distinct file paths matched by FILE_PATTERN over the
whole body (not just a "Files:" section), de-duplicated.

Output contract (JSON, single line, on stdout):
    {"tier": "TRIVIAL" | "STANDARD" | "RISKY",
     "signals": {
         "ac_count": int,
         "listed_files": int,
         "keywords": [str, ...]}}

Callers: scripts/nightcrawler.sh::derive_complexity_tier (subprocess).
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


def count_ac_bullets(body: str) -> int:
    """Bullets inside an Acceptance-ish section, else total bullets."""
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
    """Distinct file-path matches across the body."""
    return len({m.group(0) for m in FILE_PATTERN.finditer(body)})


def find_keywords(body: str) -> List[str]:
    """Case-insensitive whole-word RISKY keyword hits, in canonical order."""
    lowered = body.lower()
    return [kw for kw in RISKY_KEYWORDS if re.search(rf"\b{re.escape(kw)}\b", lowered)]


def derive_tier(body: str) -> Tuple[str, Dict]:
    ac = count_ac_bullets(body)
    files = count_listed_files(body)
    kws = find_keywords(body)
    if kws:
        tier = "RISKY"
    elif ac <= 2 and files <= 1:
        tier = "TRIVIAL"
    else:
        tier = "STANDARD"
    return tier, {"ac_count": ac, "listed_files": files, "keywords": kws}


def main() -> int:
    body = sys.stdin.read()
    tier, signals = derive_tier(body)
    json.dump({"tier": tier, "signals": signals}, sys.stdout, separators=(",", ":"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
