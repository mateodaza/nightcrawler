# Nightcrawler — Orchestrator Specification (v2)

## 1. Overview

Nightcrawler is an autonomous implementation orchestrator built on OpenClaw. It takes a manually-defined plan and task queue, then executes implementation loops overnight using a multi-model pipeline: Claude Opus for planning, Claude Sonnet for implementation, and OpenAI Codex for independent audit and review.

You plan. Nightcrawler implements. You review.

## 2. System Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                        NIGHTCRAWLER                           │
│                                                               │
│  ┌───────────┐    ┌────────────────────────────────────────┐ │
│  │ Telegram   │◄──►│  OpenClaw (orchestrator)               │ │
│  │ (Mateo)    │    │                                        │ │
│  └───────────┘    │  ┌──────────────────────────────────┐  │ │
│                    │  │ Session Controller                │  │ │
│                    │  │ - Session journal (WAL)           │  │ │
│                    │  │ - Task queue consumer             │  │ │
│                    │  │ - Dependency resolver             │  │ │
│                    │  │ - Loop state machine              │  │ │
│                    │  │ - Lock detector                   │  │ │
│                    │  │ - Budget tracker (pre-call)       │  │ │
│                    │  │ - Report generator                │  │ │
│                    │  └──────┬───────────────┬───────────┘  │ │
│                    └─────────┼───────────────┼──────────────┘ │
│                              │               │                 │
│                    ┌─────────▼──┐    ┌───────▼────────┐       │
│                    │ Claude Code │    │  Codex         │       │
│                    │ (Podman)    │    │  (Podman/API)  │       │
│                    │             │    │                │       │
│                    │ Opus: plan  │    │ Audit plans    │       │
│                    │ Sonnet: code│    │ Review code    │       │
│                    └─────────────┘    └────────────────┘       │
│                                                               │
│  PROJECT REPO (read/write)       NIGHTCRAWLER REPO (state)    │
│  ├── GLOBAL_PLAN.md (read only)  ├── memory.md                │
│  ├── TASK_QUEUE.md (consume)     ├── sessions/<session-id>/   │
│  ├── PROGRESS.md (update)        │   ├── journal.jsonl        │
│  ├── memory.md (update)          │   ├── report.md            │
│  ├── BLOCKERS.md (append)        │   ├── cost.jsonl           │
│  │ (lockfile in /tmp, not repo)   │   ├── decisions.md         │
│  └── src/ (implement)            │   └── tasks/<task-id>/     │
│                                  │       └── mini_plan.md     │
│                                  └── config/                  │
└──────────────────────────────────────────────────────────────┘
```

## 3. Session Identity

Every session gets a unique ID: `<YYYYMMDD>-<HHMMSS>-<project>` (e.g., `20260228-234500-clout`).

This ID is used for:
- Session directory: `sessions/20260228-234500-clout/`
- Git branch: `nightcrawler/20260228-234500-clout`
- Lockfile PID tracking
- Heartbeat metadata
- All Telegram messages reference it for context

No two sessions can collide, even on the same day.

## 4. The Implementation Loop

### 4.1 Session Lifecycle

```
SESSION START
  │
  ├── 1. Generate session ID
  ├── 2. CRASH RECOVERY CHECK: scan sessions/*-<project>/journal.jsonl for the current project's most recent session
  │       → Only match sessions for THIS project (session IDs end with -<project>)
  │       → Even if no lockfile exists (it may have been cleaned before crash)
  │       → If incomplete terminal event found: reconcile state (see §4.2 crash recovery), then continue startup
  ├── 3. Check for stale lockfile: if /tmp/nightcrawler-<project>.lock exists and PID dead, clean it up
  │       → If lock exists and PID alive → REFUSE to start, notify Telegram
  ├── 4. Verify repo is on configured base branch (source of truth: openclaw.yaml → projects.<name>.base_branch)
  │       → If on wrong branch or detached HEAD → REFUSE to start, notify Telegram
  ├── 5. Verify clean worktree: git status --porcelain must be empty
  │       → If dirty → REFUSE to start, notify Telegram with dirty file list
  ├── 6. Acquire lockfile: write to /tmp/nightcrawler-<project>.lock (OUTSIDE repo)
  │       → Contains: PID, session ID, project path, timestamp
  │       → Lockfile lives outside git worktree to avoid contaminating clean status
  ├── 7. Switch to dev branch: git checkout nightcrawler/dev || git checkout -b nightcrawler/dev
  ├── 8. Create session directory: sessions/<session-id>/
  ├── 9. Initialize session journal: sessions/<session-id>/journal.jsonl
  ├── 10. Start heartbeat (touch file every 10 min with session ID + PID)
  ├── 11. Read project GLOBAL_PLAN.md (context, never modify)
  ├── 12. Read project TASK_QUEUE.md
  ├── 13. Reconcile: check for stale [~] In Progress markers from crashed sessions
  │       → If found, reset to [ ] Queued and log warning
  ├── 14. Read project memory.md + PROGRESS.md
  ├── 15. Read nightcrawler/memory.md (orchestrator learnings)
  ├── 16. Load nightcrawler/config/ (models, budget, rules)
  ├── 17. Validate Codex availability (test call)
  │       → If Codex CLI fails → try API fallback
  │       → If both fail → REFUSE to start, release lock, notify Telegram
  ├── 18. BASELINE CHECK: run full build + test suite, record last-known-green commit hash
  │       → If tests already fail → notify Telegram "repo is red before session", release lock, stop
  ├── 19. Initial dependency scan: mark tasks whose dependencies are in terminal failure (BLOCKED, SKIPPED, LOCKED) as DEP_BLOCKED
  │       → Tasks whose dependencies are not yet COMPLETED stay QUEUED (re-evaluated dynamically — see TASK LOOP below)
  ├── 20. Send Telegram: "▶️ Session <id> started. [N] tasks. Budget: $[X]."
  │
  ▼
TASK LOOP
  │
  ├── PICK NEXT TASK (dynamic — runs every iteration, not precomputed)
  │   ├── Re-read TASK_QUEUE.md for current states
  │   ├── Find first QUEUED task whose dependencies are ALL in COMPLETED state
  │   │   → If a dependency is still QUEUED or IN_PROGRESS → skip this task for now, check the next QUEUED task
  │   │   → If a dependency is in terminal failure (BLOCKED, SKIPPED, LOCKED) → mark this task DEP_BLOCKED
  │   ├── If no eligible task found → SESSION END (normal completion)
  │   └── Selected task becomes current task
  │
  ├── JOURNAL: write {"event": "task_start", "task_id": "NC-001", "timestamp": "..."}
  │
  ├── BUDGET GATE: check if remaining budget (cap - spent - $2 reserve) > $1
  │   → If not → stop session, proceed to SESSION END
  │
  ├── PHASE 0: PRE-FLIGHT CHECK
  │   ├── 01. Run full build + test suite
  │   ├── 02. If tests fail AND were passing at baseline → identify breaking commit
  │   │       → Log in BLOCKERS.md with commit hash
  │   │       → Escalate to Telegram with specific commit blame
  │   │       → Park ALL remaining tasks until resolved
  │   ├── 03. If tests fail AND were ALSO failing at baseline → this was pre-existing, skip
  │   └── 04. If tests pass → proceed to Phase A
  │
  ├── PHASE A: MINI-PLAN
  │   ├── A1. BUDGET CHECK: estimate Opus call cost, reject if over remaining budget
  │   ├── A2. Opus reads task + project context
  │   ├── A3. Opus writes mini-plan → save to sessions/<session-id>/tasks/<task-id>/mini_plan.md
  │   ├── A4. BUDGET CHECK: estimate Codex call cost
  │   ├── A5. Codex audits mini-plan
  │   ├── A6. If rejected → Opus revises with Codex feedback → A4
  │   ├── A7. If lock (3 iterations OR Jaccard >0.5 on last 3) → escalate → park task
  │   ├── A8. JOURNAL: write plan audit result
  │   └── A9. If approved → proceed to Phase B
  │
  ├── PHASE B: IMPLEMENT
  │   ├── B1. BUDGET CHECK: estimate Sonnet call cost
  │   ├── B2. Sonnet implements the approved mini-plan
  │   ├── B3. Sonnet runs tests (forge test, npm test, etc.)
  │   ├── B4. BUDGET CHECK: estimate Codex call cost
  │   ├── B5. Codex reviews implementation + test results
  │   ├── B6. If rejected → Sonnet revises with Codex feedback → B2
  │   ├── B7. If lock (3 iterations OR Jaccard >0.5 on last 3) → escalate → park task
  │   ├── B8. JOURNAL: write implementation review result
  │   └── B9. If approved → proceed to Phase C
  │
  ├── PHASE C: CLOSE TASK
  │   ├── C1. JOURNAL: write {"event": "committing", "task_id": "NC-001"}
  │   ├── C2. Commit with structured message
  │   ├── C3. POST-COMMIT VERIFICATION
  │   │       → Run full build + test suite (not just new tests)
  │   │       → If fails → auto-revert commit (git revert HEAD --no-edit)
  │   │       → JOURNAL: write {"event": "reverted", "reason": "..."}
  │   │       → Re-enter Phase B with integration error as feedback
  │   │       → If 2nd revert on same task → LOCK, escalate
  │   ├── C4. JOURNAL: write {"event": "task_completed", "task_id": "NC-001", "commit": "abc123"}
  │   ├── C5. Update project PROGRESS.md
  │   ├── C6. Update project memory.md (new patterns, decisions)
  │   ├── C7. Mark task as COMPLETED in TASK_QUEUE.md (with session ID + commit hash)
  │   ├── C8. Send Telegram notification (batched if NORMAL priority)
  │   └── C9. Check budget → if effective budget < $1 → stop admitting new tasks
  │
  └── Next task or end session
      │
      ▼
SESSION END (always runs, even on crash recovery — uses reserved $2 budget)
  ├── JOURNAL: write {"event": "session_ending", "reason": "..."}
  ├── Generate daily report → sessions/<session-id>/report.md
  ├── Generate cost breakdown → sessions/<session-id>/cost.jsonl
  ├── Update nightcrawler/memory.md with session learnings
  ├── JOURNAL: write + fsync {"event": "session_complete"}  ← MUST be durable before cleanup
  ├── Send Telegram: "⏹️ Session <id> done. Report ready."
  ├── Release lockfile (/tmp/nightcrawler-<project>.lock)
  ├── Delete heartbeat file
  └── Stop
  NOTE: Lock and heartbeat are cleaned AFTER the terminal journal event is durable.
        On next startup, scan journals for session_complete even if no lockfile exists.
```

### 4.2 Session Journal (Write-Ahead Log)

The journal (`sessions/<session-id>/journal.jsonl`) is a durable, append-only log of every state transition. It is the crash recovery mechanism.

Each line is a JSON object:
```json
{"event": "session_start", "session_id": "20260228-234500-clout", "timestamp": "2026-02-28T23:45:00Z", "tasks": 5, "budget": 20.00}
{"event": "task_start", "task_id": "NC-001", "timestamp": "2026-02-28T23:46:12Z"}
{"event": "plan_approved", "task_id": "NC-001", "iterations": 2, "cost": 0.14}
{"event": "impl_approved", "task_id": "NC-001", "iterations": 1, "cost": 0.21}
{"event": "committing", "task_id": "NC-001", "timestamp": "2026-02-28T23:52:00Z"}
{"event": "task_completed", "task_id": "NC-001", "commit": "abc123f", "cost": 0.42}
{"event": "task_start", "task_id": "NC-002", "timestamp": "2026-02-28T23:53:00Z"}
```

**Crash recovery on next startup:**
1. Scan `sessions/*-<project>/journal.jsonl` for the most recent session matching the CURRENT project
   (Session IDs end with `-<project>`, e.g., `20260228-234500-clout`. Only match journals for this project to avoid cross-project interference.)
2. Check if it has a terminal `session_complete` event
   - If yes → clean shutdown, no recovery needed
   - If no → previous session crashed (regardless of whether lockfile exists)
3. Read the incomplete journal to determine last successful state:
   a. If last event is `committing` but no `task_completed` → check if commit exists in git
      - If commit exists but TASK_QUEUE.md not updated → update it
      - If commit doesn't exist → task was interrupted, reset to QUEUED
   b. If last event is `task_start` with no completion → reset that task to QUEUED
   c. If last event is `session_ending` but no `session_complete` → report may be incomplete, regenerate
4. Clean up stale lockfile (if exists) and heartbeat (if exists)
5. Clean up stale [~] In Progress markers in TASK_QUEUE.md
6. Log recovery actions to new session journal

### 4.3 Loop State Machine

Each task goes through these states:

```
QUEUED → PLANNING → PLAN_AUDIT → PLAN_REVISION → PLAN_APPROVED
  → IMPLEMENTING → IMPL_REVIEW → IMPL_REVISION → IMPL_APPROVED
  → COMMITTING → VERIFYING → COMPLETED

Special states:
  → LOCKED (Opus/Codex disagreement unresolved, escalated to Telegram, parked)
  → BLOCKED (manual/external blocker — missing secret, infra issue, etc. — logged, escalated)
  → SKIPPED (permanently skipped by Mateo's decision)
  → DEP_BLOCKED (upstream dependency is in terminal failure: BLOCKED/SKIPPED/LOCKED — auto-skipped)
  → MANUAL (Mateo-only task, marked [🚧] — orchestrator skips automatically, no state transition)
```

### 4.4 Lock Detection Algorithm

Lock detection uses keyword overlap, not semantic analysis. No model judges its own disagreement.

A lock triggers when EITHER condition is met (whichever comes first):
- **Hard cap:** 3 iterations reached in the same phase (plan or implementation)
- **Theme repetition:** Jaccard keyword overlap >0.5 across the last 3 rejections

```
lock_threshold = 3
feedback_history = []  # stores normalized keyword sets per rejection

on each Codex rejection:
    keywords = extract_keywords(feedback)
    # extract_keywords: lowercase, remove stopwords, split on whitespace/punctuation
    feedback_history.append(keywords)

    # Hard cap check
    if len(feedback_history) >= lock_threshold:
        trigger LOCK

    # Theme repetition check (if at least 3 entries)
    if len(feedback_history) >= 3:
        recent = feedback_history[-3:]
        overlap = avg_jaccard(recent)
        if overlap > 0.5:
            trigger LOCK

    on LOCK:
        → log both positions in BLOCKERS.md (include raw feedback from last 3 iterations)
        → send Telegram message with summary
        → park task, move to next
```

Note: keyword extraction is pure string processing (split, lowercase, stopword removal). No model involved. Deterministic, cheap, auditable.

## 5. Model Configuration

### 5.1 Model Assignments

| Phase | Model | Mode | Rationale |
|-------|-------|------|-----------|
| Mini-planning | Claude Opus 4.6 | via Claude Code CLI | Best reasoning for implementation approach |
| Plan revision | Claude Opus 4.6 | via Claude Code CLI | Needs same reasoning depth to address feedback |
| Implementation | Claude Sonnet 4.6 | via Claude Code CLI | Best cost/quality for code gen with approved plan |
| Implementation revision | Claude Sonnet 4.6 | via Claude Code CLI | Same model maintains code consistency |
| Plan audit | Codex-mini | via Codex CLI or API | Independent perspective, cheapest for review |
| Implementation review | Codex-mini | via Codex CLI or API | Independent perspective, catches different bugs |
| Report generation | Claude Sonnet 4.6 | via Claude Code CLI | Structured output, cost-efficient |

### 5.2 Auditor Configuration

The audit role uses the **Codex-mini model**. Two interfaces are supported:

1. **Codex CLI** (preferred) — runs in Podman container, interactive terminal agent
2. **OpenAI API direct** (fallback) — direct chat completions call with codex-mini-latest

At session start, Nightcrawler tests Codex CLI headlessly. If it works, use it for the session. If it fails (hangs, auth error, interactive prompt), switch to API direct for the entire session. Log which interface is active in the journal.

**Both interfaces use the same model and produce equivalent audit quality.** The difference is only in how the request is sent. This is NOT a policy violation — the independent audit guarantee comes from using a non-Claude model, not from the specific CLI tool.

If BOTH Codex CLI and OpenAI API are unavailable → pause and escalate. Never substitute Claude.

### 5.3 Fallback Policy

| Component down | Action | Rationale |
|---------------|--------|-----------|
| Opus (planner) | Pause and escalate | Planning quality is critical, Sonnet is insufficient |
| Sonnet (implementer) | Pause and escalate | Don't use Opus for implementation (too expensive) |
| Codex CLI | Switch to OpenAI API direct | Same model, different interface |
| Codex CLI + OpenAI API | Pause and escalate | Independent audit is non-negotiable |

### 5.4 Cost Optimization

**Prompt caching (Claude API):**
- Structure all prompts with static prefix first: RULES + GLOBAL_PLAN + project memory
- Dynamic content (task, feedback) goes at the end
- Cache hits cost 0.1x input — saves ~60% on loop iterations
- Cache TTL: 5 minutes (sufficient for loop speed)

**Token management:**
- Mini-plans: cap Opus output at 2K tokens (force conciseness)
- Implementation: cap Sonnet output at estimated remaining task budget worth of tokens (dynamic ceiling prevents runaway output from blowing budget before the gate catches it)
- Codex audits: cap at 1K tokens (verdict + specific feedback only)
- Context window: prune conversation history between tasks (each task starts fresh)

**Loop context pruning:**
- Each loop iteration sends ONLY: latest plan/code + latest Codex feedback
- Previous iterations are compressed to a single-line summary each:
  "Iteration 1: rejected — missing error handling for timeout edge cases."
  "Iteration 2: rejected — revert logic incomplete for DRAW outcome."
- This prevents context blowup on 3-iteration loops (saves ~40% input tokens on iteration 3)
- Full iteration history is preserved in the mini-plan audit trail (file), not in the prompt

## 6. Budget System

### 6.1 Budget Enforcement

Budget is checked BEFORE every model call, not after task completion.

```
effective_budget = session_cap - reserve - spent_so_far
reserve = 2.00  # for report generation, final notifications, potential revert

before each model call:
    estimated_cost = estimate_cost(model, estimated_input_tokens, max_output_tokens)
    if estimated_cost > effective_budget:
        → stop admitting new work
        → proceed to SESSION END (uses reserve)
```

### 6.2 Budget Tracking

```yaml
# Tracked per session
session_budget_cap: 20.00  # USD, configurable
reserve: 2.00              # for mandatory end-of-session work
alert_threshold: 0.80      # 80% of effective budget → Telegram warning
hard_stop: 1.00            # effective budget < $1 → stop new tasks

# Tracked per task
task_cost: 0.00            # running total for current task
task_cost_alert: 5.00      # single task > $5 → something is wrong → escalate

# Tracked cumulative (UTC day boundaries)
daily_cap: 50.00           # hard daily maximum across all sessions
monthly_cap: 200.00        # hard monthly maximum
billing_timezone: UTC       # all day boundaries use UTC
```

### 6.3 Cost Logging

After every API call, append one line to `sessions/<session-id>/cost.jsonl` (JSONL, not JSON):
```jsonl
{"timestamp": "2026-02-28T03:42:00Z", "task_id": "NC-001", "phase": "implementation", "model": "sonnet-4.6", "input_tokens": 10234, "output_tokens": 8891, "cached_tokens": 6200, "cost_usd": 0.18, "session_total_usd": 4.32, "effective_remaining_usd": 13.68}
```

## 7. Project Integration

### 7.1 What Nightcrawler Reads (never modifies)

| File | Purpose |
|------|---------|
| `GLOBAL_PLAN.md` | Your master plan — phases, features, architecture |
| `RULES.md` (nightcrawler repo) | Safety and project constraints |
| `config/*.yaml` | Model assignments, budget, OpenClaw config |

### 7.2 What Nightcrawler Writes

| File | Location | Purpose |
|------|----------|---------|
| `PROGRESS.md` | project repo | Current state vs. Global Plan |
| `memory.md` | project repo | Codebase patterns, decisions, context |
| `BLOCKERS.md` | project repo | Things that need your attention |
| `TASK_QUEUE.md` | project repo | Marks tasks as completed/blocked |
| `/tmp/nightcrawler-<project>.lock` | /tmp (outside repo) | Session lock (PID + session ID + project path) |
| `memory.md` | nightcrawler repo | Orchestrator learnings |
| `sessions/<session-id>/journal.jsonl` | nightcrawler repo | Write-ahead log for crash recovery |
| `sessions/<session-id>/report.md` | nightcrawler repo | Session report (completed, reverted, blocked) |
| `sessions/<session-id>/cost.jsonl` | nightcrawler repo | Per-call cost log (append-only JSONL) |
| `sessions/<session-id>/decisions.md` | nightcrawler repo | Key decisions made during session (which approach chosen, lock resolutions) |
| `sessions/<session-id>/tasks/*/mini_plan.md` | nightcrawler repo | Approved mini-plans with audit trail |

### 7.3 What Nightcrawler Commits

Every commit follows this format:
```
[nightcrawler] <type>: <short description>

Task: <task-id> — <task name>
Session: <session-id>
Phase: <plan|implement>
Model: <opus|sonnet>
Audit: <approved by codex after N iterations>
Cost: $<task cost>

<detailed description of what was done and why>
```

Types: `feat`, `fix`, `refactor`, `test`, `chore`

## 8. Task Queue Format

Tasks use **stable IDs** (NC-001, NC-002, etc.), not positional numbers. IDs never change when tasks are reordered or inserted.

```markdown
## Task Queue

### Status Legend
- [ ] Queued
- [~] In Progress (session: <session-id>)
- [x] Completed (session: <session-id>, commit: <hash>)
- [!] Blocked
- [?] Needs Clarification
- [🔒] Locked

### Tasks

#### NC-001 [x] Implement CloutEscrow.sol core struct and state machine
- **Acceptance criteria:** Challenge struct, ChallengeState enum, WalletRecord struct, state transition functions
- **Dependencies:** None
- **Constraints:** Follow OpenZeppelin patterns, ReentrancyGuard on all external calls
- **Completed:** session 20260228-234500-clout, commit abc123f, $0.42

#### NC-002 [ ] Add timeout logic to CloutEscrow
- **Acceptance criteria:** All 6 timeout specs from GLOBAL_PLAN, auto-void on admin timeout
- **Dependencies:** NC-001
- **Constraints:** Use block.timestamp, test with foundry cheatcodes (vm.warp)

#### NC-003 [ ] Implement CloutPool.sol challenge pools
- **Acceptance criteria:** YES/NO pools, per-wallet caps, host commission, designated resolver
- **Dependencies:** NC-001
- **Constraints:** Host cannot be resolver, host must stake YES side
```

## 9. Daily Report Specification

See `templates/daily_report.md` for the full template. Key sections:

**For You (project progress):**
- Tasks completed with commit hashes (zero failing tests guaranteed for each)
- Tasks blocked/locked/skipped with reasons
- Reverted attempts (separate section — not mixed with completed)
- Suggestions for your day session
- Architecture decisions that need your input

**For the Orchestrator (self-improvement):**
- Loop efficiency metrics (avg iterations per approval)
- Pattern detection (what Codex consistently flags)
- Rule suggestions (new constraints to add to CLAUDE.md)
- Cost analysis (which phases burned most tokens)
- Lock analysis (what caused disagreements)

## 10. Pre-Flight Validation (before first real session)

Before trusting Nightcrawler overnight, validate these manually:

### 10.1 Codex Headless Test

```bash
# Test 1: Codex CLI
codex -p "Review: function add(a,b){return a+b} — Reply APPROVED or REJECTED with feedback."
# Expected: structured text, clean exit, no interactive prompt

# Test 2: OpenAI API fallback
python3 -c "
import openai
r = openai.chat.completions.create(
    model='codex-mini-latest',
    messages=[{'role':'user','content':'Review: function add(a,b){return a+b} — Reply APPROVED or REJECTED.'}]
)
print(r.choices[0].message.content)
"
# Expected: structured text with verdict
```

Both must be tested. Session startup auto-selects the working one.

### 10.2 Dry Run Mode

```yaml
dry_run: true  # in config/budget.yaml
```

**Dry run behavior:**
- Session setup (lock, branch, baseline): runs normally
- Phase 0 (pre-flight): runs normally
- Phase A (mini-plan + audit): runs fully
- Phase B (implementation): SKIPPED entirely
- Phase C: saves approved mini-plans to `sessions/<session-id>/tasks/<task-id>/mini_plan.md`
- Report: generated as normal, marked as dry run

Costs ~30% of a real session. Review mini-plans before running for real.

### 10.3 Watchdog (independent of OpenClaw)

```bash
#!/bin/bash
# /home/nightcrawler/scripts/watchdog.sh — runs via cron, independent of OpenClaw
HEARTBEAT_FILE="/tmp/nightcrawler-heartbeat"
ALERTED_FILE="/tmp/nightcrawler-watchdog-alerted"
MAX_AGE_MINUTES=30

if [ ! -f "$HEARTBEAT_FILE" ]; then
    # No heartbeat = no active session, clean up alert state
    rm -f "$ALERTED_FILE"
    exit 0
fi

# Read session ID from heartbeat
SESSION_ID=$(cat "$HEARTBEAT_FILE" | head -1)
FILE_AGE=$(( ($(date +%s) - $(stat -c %Y "$HEARTBEAT_FILE")) / 60 ))

if [ "$FILE_AGE" -gt "$MAX_AGE_MINUTES" ]; then
    # Only alert once per stale session
    if [ -f "$ALERTED_FILE" ] && [ "$(cat "$ALERTED_FILE")" = "$SESSION_ID" ]; then
        exit 0  # already alerted for this session
    fi

    # Send alert (Twilio fallback — uses WhatsApp transport as Telegram backup)
    curl -s -X POST "https://api.twilio.com/..." \
        -d "Body=⚠️ Nightcrawler watchdog: session $SESSION_ID unresponsive for ${FILE_AGE}m." \
        -d "To=whatsapp:+YOURNUMBER" \
        -d "From=whatsapp:+TWILIONUMBER"

    echo "$SESSION_ID" > "$ALERTED_FILE"
fi
```

Cron: `*/30 * * * * nightcrawler /home/nightcrawler/scripts/watchdog.sh`

Heartbeat file contains: session ID (line 1) + PID (line 2). Deleted on clean shutdown. Watchdog alerts once per stale session, not repeatedly.

## 11. Memory Management

### 11.1 Memory Pruning

**Orchestrator memory (`nightcrawler/memory.md`):**
- Max active section: 100 lines
- When exceeded: summarize entries older than 7 days into `## Historical` section
- Historical section: max 50 lines (oldest dropped)
- Pruning at session start

**Project memory (`<project>/memory.md`):**
- Max active section: 150 lines. Same pruning strategy.

**Mini-plan artifacts (`sessions/<session-id>/tasks/<task-id>/`):**
- Always persisted, never pruned. These are the audit trail for what was planned.

**Session logs (`sessions/<session-id>/`):**
- Never auto-pruned. Archive manually.

### 11.2 What Goes Into Memory

**Write:** coding patterns, implementation decisions, recurring Codex feedback themes, model behavior observations.

**Do NOT write:** task-specific details (live in commits), debugging info, cost data (live in cost.jsonl), Global Plan content (reference, don't copy).

### 11.3 Initial Memory Format

Memory files use explicit empty markers, not placeholders:
```markdown
## Model Behaviors
None yet.

## Recurring Patterns
None yet.
```

## 12. Deployment

### 12.1 Infrastructure

- **Hetzner CX23** (2 vCPU, 4GB RAM, $3.49/mo)
- **Podman** for container isolation (Claude Code + Codex CLI)
- **OpenClaw** as the orchestrator runtime
- **tmux** for persistent sessions
- Dedicated `nightcrawler` user (not root)

### 12.2 Environment

```bash
# Required API keys (in /home/nightcrawler/.env, loaded by OpenClaw)
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...

# Twilio (for watchdog fallback — loaded by cron script)
# Note: Twilio env var names reference "whatsapp" — that's Twilio's API naming
TWILIO_ACCOUNT_SID=...
TWILIO_AUTH_TOKEN=...
TWILIO_WHATSAPP_FROM=whatsapp:+...
TWILIO_WHATSAPP_TO=whatsapp:+...

# OpenClaw config — primary messaging is Telegram (see openclaw.yaml)
OPENCLAW_TELEGRAM_ENABLED=true

# Nightcrawler config
NIGHTCRAWLER_PROJECT_PATH=/home/nightcrawler/projects/clutch
NIGHTCRAWLER_STATE_PATH=/home/nightcrawler/nightcrawler
NIGHTCRAWLER_SESSION_BUDGET=20.00
NIGHTCRAWLER_DAILY_CAP=50.00
```

### 12.3 Security

- API keys stored in environment only, never in repo
- Podman containers run rootless with dropped capabilities
- Claude Code restricted via `--allowedTools` (no curl, no ssh, no git push)
- Orchestrator egress allowlist: api.anthropic.com, api.openai.com, api.twilio.com, registry.npmjs.org, github.com (fetch only)
- All project git operations are local commits only — Mateo pushes manually
- Subprocess timeouts enforced (see RULES.md timeout table)
- Lockfile prevents concurrent sessions on same project

### 12.4 Graceful Session Timeout

`max_duration_hours: 10` is a safety net. When hit:
1. Stop admitting new tasks (do NOT kill mid-phase)
2. If currently in Phase A or B: finish the current iteration, then stop
3. If currently in Phase C: finish the commit + verification
4. Proceed to SESSION END (report, cleanup, release lock)
5. Telegram: "⏹️ Session <id> hit max duration. [N] tasks done. Report ready."

Never hard-kill during a commit, verification, or state update.
