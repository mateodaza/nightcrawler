# Escalation Protocol (v2)

When and how Nightcrawler messages you on Telegram. Every possible escalation is listed here. If it's not on this list, Nightcrawler handles it autonomously.

Every message includes the session ID for context. All task references use stable NC-xxx IDs.

## Blocking Escalations (Nightcrawler pauses the task and waits)

### Lock Detected
**Trigger:** Lock condition met — 3 iterations (hard cap) OR Jaccard keyword overlap >0.5 across last 3 rejections, whichever fires first.
**Action:** Park current task as LOCKED, move to next. Wait for your response to resume this task.
**Message format:**
```
🔒 LOCK — Session <session-id>
Task: NC-<xxx> "<task name>"
Phase: <plan / implementation>
Trigger: <hard cap 3 / Jaccard >0.5>
Opus: <position in 1 sentence>
Codex: <position in 1 sentence>
Iterations: <N>
→ Reply: 1=Opus  2=Codex  3=Skip
  Or type custom instruction.
```

### Budget Exceeded
**Trigger:** Session spend reaches 100% of effective budget (cap - reserve).
**Action:** Stop all new work immediately. Proceed to SESSION END (uses $2 reserve for report).
**Message format:**
```
💰 BUDGET — Session <session-id>
Cap: $<cap>  Spent: $<spent>  Reserve: $2
Tasks done: <N>  Remaining: <N>
→ Reply: raise <number> (e.g. "raise 30")
  Or: stop
```

### Ambiguous Task
**Trigger:** Task in queue lacks clear acceptance criteria or contradicts the Global Plan.
**Action:** Skip task (mark NEEDS_CLARIFICATION), continue with next.
**Message format:**
```
❓ UNCLEAR — Session <session-id>
Task: NC-<xxx> "<task name>"
Reason: <missing criteria / contradicts plan / too vague>
→ Reply: skip  OR  type clarification
  (Clarification saved to decisions.md — does NOT modify TASK_QUEUE.md)
```

### Test Failures Post-Approval
**Trigger:** Codex approved implementation but tests fail after 2 fix attempts.
**Action:** Park task, continue with next.
**Message format:**
```
🧪 TESTS FAIL — Session <session-id>
Task: NC-<xxx> "<task name>"
Failing: <test names>
Error: <1-line summary>
Attempts: <N>
→ Reply: skip  OR  type hint for retry
```

### Codex Unavailable (both CLI and API)
**Trigger:** Both Codex CLI and OpenAI API direct fail at session start or during session.
**Action:** Stop session. Never substitute Claude for the audit role. Note: if only CLI fails but API works, session continues on API — this is NOT an escalation.
**Message format:**
```
⚠️ CODEX DOWN — Session <session-id>
CLI error: <1-line>
API error: <1-line>
Session paused — independent audit is non-negotiable.
→ Check OpenAI status, then reply: resume  OR  stop
```

### Pre-Flight Test Failure (new since baseline)
**Trigger:** Full test suite fails BEFORE starting a new task, AND these failures are NEW (not present at session baseline). Means a previous task's commit broke something.
**Action:** Stop ALL task processing.
**Message format:**
```
🚨 PRE-FLIGHT FAIL — Session <session-id>
Failing: <test names>
Breaking commit: <hash> (task NC-<xxx>)
Baseline was green at: <baseline commit hash>
→ Reply: revert  OR  stop
```

### Post-Commit Integration Failure (2nd revert)
**Trigger:** A task's commit was reverted twice because it breaks the build even after Codex approved it.
**Action:** Park task as LOCKED.
**Message format:**
```
🔄 2x REVERT — Session <session-id>
Task: NC-<xxx> "<task name>"
Error: <1-line summary>
→ Needs manual investigation. Moving to next task.
  Reply: acknowledged  (or any reply to confirm receipt)
```

### Watchdog Alert (sent by cron, NOT OpenClaw)
**Trigger:** OpenClaw hasn't updated heartbeat file in 30+ minutes during an active session.
**Action:** Independent cron job sends Telegram alert (via Twilio fallback if Telegram is down). OpenClaw is likely dead.
**Message format:**
```
⚠️ WATCHDOG — Session <session-id>
OpenClaw unresponsive for <N>m.
Last heartbeat: <timestamp>
→ SSH into server and check. May need restart.
```

## Non-Blocking Notifications (Nightcrawler continues working)

### Session Started
**When:** Session begins successfully.
```
▶️ Session <session-id> started.
Tasks: <N> queued, <N> dep-blocked.
Budget: $<effective> ($<cap> - $2 reserve).
Auditor: <codex-cli / openai-api>.
Base branch: <branch>.
```

### Task Completed
**When:** After each task is committed and post-commit verified.
```
✅ NC-<xxx> "<task name>" — commit <hash>.
Remaining: <N>. Spent: $<spent>/$<cap>.
```

### Budget Warning
**When:** Spend hits 80% of effective budget.
```
⚠️ Budget 80% — $<spent>/$<cap>. <N> tasks left.
Continuing unless you say stop.
```

### Session Ended
**When:** Session finishes (queue empty, budget hit, or all tasks processed).
```
⏹️ Session <session-id> done.
Completed: <N>  Blocked: <N>  Locked: <N>  Remaining: <N>
Cost: $<total>.
Report: nightcrawler/sessions/<session-id>/report.md
```

### Blocker Logged
**When:** Task skipped due to external dependency or DEP_BLOCKED.
```
🚫 NC-<xxx> "<task name>" — skipped.
Reason: <dependency NC-yyy is BLOCKED / external dep missing>.
Logged in BLOCKERS.md. Continuing.
```

## Rate Limits & Priority

Messages have two priority classes:

**URGENT (blocking escalations):** Always send immediately. Bypass rate limits. Bypass batching. These are: Lock Detected, Budget Exceeded, Pre-Flight Failure, Codex Unavailable, Watchdog Alert, 2x Revert.

**NORMAL (notifications):** Batch in 15-minute windows. Cap at 5/hour. These are: Session Started, Task Completed, Budget Warning, Session Ended, Blocker Logged.

Duplicate coalescing: if the same escalation type fires for the same task (same NC-xxx ID), don't resend. One alert per event per task.

## Response Handling

### Parsing Rules (v2 — exact match, no fuzzy)

All response parsing uses **exact per-escalation parsers**. No generic fuzzy matching. No substring matching. Each escalation type has its own accepted responses.

**Pre-match normalization:** Before matching, the orchestrator normalizes the incoming Telegram message: strip leading/trailing whitespace, then lowercase. All patterns below are written in lowercase and match against the normalized input. This prevents harmless case differences (e.g., "Skip", "SKIP", "skip") from causing parse failures while still rejecting genuinely ambiguous replies.

Before executing ANY parsed action, send a confirmation message:
```
✓ Parsed: <action description>. Proceeding.
```

If a response cannot be parsed:
```
❓ Didn't understand that. Accepted replies for this escalation:
<list of valid responses for this specific escalation type>
```

After 2 unparseable responses to the same escalation, park the task and continue.

### Per-Escalation Response Parsers

**Lock Detected:**
- `1` → Use Opus's approach (exact match: string is exactly "1")
- `2` → Use Codex's approach (exact match: string is exactly "2")
- `3` or `skip` → Permanently skip this task (exact match)
- Anything else that doesn't match above → Custom instruction. Save to `sessions/<session-id>/decisions.md`. Add as hard constraint for this task only. Retry.
- Confirmation: `✓ Using Opus's approach for NC-<xxx>. Resuming.`

**Budget Exceeded:**
- Regex: `^raise\s+(\d+)$` → New cap = captured number (e.g., "raise 30" → $30). The word "raise" is required.
- `stop` → End session (exact match)
- Confirmation: `✓ Budget raised to $<N>. Resuming.` or `✓ Ending session.`

**Ambiguous Task:**
- `skip` → Permanently skip (exact match)
- Anything else → Clarification text. Save to `sessions/<session-id>/decisions.md` as per-session constraint for this task. Do NOT modify TASK_QUEUE.md. Retry task with clarification as added context.
- Confirmation: `✓ Clarification saved for NC-<xxx>. Retrying with your input.`

**Test Failures:**
- `skip` → Park for day session (exact match)
- Anything else → Treat as hint. Save to decisions.md. Retry with hint as context.
- Confirmation: `✓ Retrying NC-<xxx> with your hint.`

**Pre-Flight / Integration Failures:**
- `revert` → Revert the problematic commit, resume from next task (exact match)
- `stop` → End session for manual investigation (exact match)
- Anything else → Save to decisions.md as fix instruction. Attempt fix.
- Confirmation: `✓ Reverting <hash>. Resuming from next task.`

**Codex Unavailable:**
- `resume` → Retry Codex connection, if still failing re-send escalation (exact match)
- `stop` → End session (exact match)

### Task Queue Modifications

**Telegram clarifications NEVER modify TASK_QUEUE.md.** Clarifications and custom instructions from Telegram replies are stored in:
- `sessions/<session-id>/decisions.md` — per-session, per-task constraints
- Session journal — logged as `{"event": "telegram_clarification", "task_id": "NC-xxx", "text": "..."}`

These are ephemeral session-level overrides. Permanent task changes require Mateo editing TASK_QUEUE.md directly during a day session.

### Task Queue Empty

This is a **normal session-end condition**, not a blocking escalation. When all tasks are consumed or remaining tasks are DEP_BLOCKED/BLOCKED:
1. Proceed to SESSION END (generate report, cleanup)
2. Send the standard Session Ended notification
3. Do NOT prompt for new tasks — new tasks are added by Mateo for the next session
