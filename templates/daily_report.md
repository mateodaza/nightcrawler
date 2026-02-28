# Session Report — {SESSION-ID}

## Summary

| Metric | Value |
|--------|-------|
| Session ID | {session-id} |
| Tasks attempted | {N} |
| Tasks completed | {N} |
| Tasks reverted | {N} |
| Tasks blocked | {N} |
| Tasks locked | {N} |
| Tasks dep-blocked | {N} |
| Total API spend | ${TOTAL} |
| Budget remaining | ${REMAINING} |
| Models used | {model list} |
| Auditor interface | {codex-cli / openai-api} |
| Duration | {Xh Ym} |
| Avg loops per task (plan) | {N} |
| Avg loops per task (impl) | {N} |

## Completed Tasks

> Each completed task has zero failing tests at commit time (post-commit verification passed).

### NC-{XXX} {Task Name}
- **Commit:** {hash}
- **Files changed:** {list}
- **Tests:** {N} passing, 0 failing (post-commit verified)
- **Plan iterations:** {N} (audited by Codex)
- **Implementation iterations:** {N} (reviewed by Codex)
- **Cost:** ${X}
- **Notes:** {any notable decisions or patterns}

## Reverted Attempts

> Tasks where implementation was committed but post-commit verification failed.
> Separated from completed tasks for clarity — these are NOT shipped.

### NC-{XXX} {Task Name} — Attempt {N}
- **Reverted commit:** {hash}
- **Failure:** {test name / build error}
- **Outcome:** {re-entered Phase B / declared LOCK}

## Blocked Tasks

### NC-{XXX} {Task Name}
- **Reason:** {description}
- **Action needed:** {what you need to do}
- **Logged in:** BLOCKERS.md

## Locked Tasks

### NC-{XXX} {Task Name}
- **Phase:** {plan / implementation}
- **Opus position:** {summary}
- **Codex position:** {summary}
- **Iterations before lock:** {N}
- **Lock trigger:** {hard cap 3 / Jaccard >0.5}
- **Your decision needed:** {specific question}

## DEP-Blocked Tasks

### NC-{XXX} {Task Name}
- **Blocked by:** NC-{YYY} (status: {BLOCKED/SKIPPED/LOCKED})

## Suggestions for Day Session

1. {Highest priority review item}
2. {Unblocking action}
3. {Next task prep}
4. {Architecture question}

---

## Orchestrator Self-Assessment

### Loop Efficiency
- Plan approval rate (first attempt): {N}%
- Implementation approval rate (first attempt): {N}%
- Avg plan iterations: {N}
- Avg implementation iterations: {N}
- Locks triggered: {N}

### Codex Feedback Patterns
- Most common plan feedback: {theme} (appeared {N} times)
- Most common impl feedback: {theme} (appeared {N} times)
- **Recommendation:** {e.g., "Add to CLAUDE.md: always include error handling for all external calls"}

### Opus Tendencies
- Observed pattern: {e.g., "Over-engineers helper functions before core logic"}
- **Recommendation:** {e.g., "Add constraint: implement core flow first, extract helpers only if needed"}

### Cost Analysis
| Phase | Total Cost | % of Session |
|-------|-----------|-------------|
| Planning (Opus) | ${X} | {N}% |
| Auditing (Codex) | ${X} | {N}% |
| Implementation (Sonnet) | ${X} | {N}% |
| Review (Codex) | ${X} | {N}% |
| Reports (Sonnet) | ${X} | {N}% |

### Budget Efficiency
- Pre-call budget gates triggered: {N} (prevented overspend of est. ${X})
- Reserve used: ${X} of $2.00
- Effective budget utilization: {N}%

### Rule Suggestions
New rules to consider adding (based on this session's patterns):
- [ ] {rule 1}
- [ ] {rule 2}

### Memory Updates
The following was added to orchestrator memory.md:
- {learning 1}
- {learning 2}
