# Nightcrawler v3 — Roadmap

> Status: DRAFT
> Date: March 7, 2026
> Previous: Generalization complete (v2). Clout (30 tasks) + Camello onboarded. Pipeline proven.

---

## Design Principle

Nightcrawler's value is the **human-AI-AI triangle**: you define scope, Sonnet executes, Codex audits independently. Humans remain the third protective layer — they set the boundaries, review the output, and decide what ships. Every feature in this roadmap preserves that triangle. Nothing runs without a human deciding it should.

---

## Tier 1: Planning & Shipping (next)

### 1.1 Nightcrawler Skill — Claude Code context for repo agents

**What it is:** A `.claude/skills/` file that lives in each project repo. When you're chatting with the project's Claude Code agent, the skill teaches it how Nightcrawler works — the TASK_QUEUE.md format, how to size tasks, how to write acceptance criteria, the dependency system, status markers, everything. The agent becomes your planning partner.

**Why a skill, not a Telegram command:** You're already in a conversation with your repo's agent when you're thinking about what to build next. That's the right moment to plan tasks — you have the codebase context, you can ask follow-ups, you can iterate. A Telegram command would generate tasks in a black box and hand you a file to review cold. The skill keeps you in the loop the entire time.

**How it works:**

You're in your project, chatting with Claude Code:
```
You: "I need to add Stripe billing. Break it down into Nightcrawler tasks."

Agent (with skill loaded):
- Reads existing TASK_QUEUE.md to see what's done and what IDs exist
- Reads codebase to understand current architecture
- Proposes tasks in the exact TASK_QUEUE.md format
- Uses correct ID prefix (CAM-XXX for camello, NC-XXX for nightcrawler)
- Writes acceptance criteria that are specific enough for Nightcrawler to verify
- Flags MANUAL tasks where human judgment is needed
- Identifies dependencies between tasks

You: "CAM-016 is too big, split it. And CAM-018 needs a dependency on CAM-015."

Agent: (revises)

You: "Good, write it to TASK_QUEUE.md"
```

Then you commit, push, and `start camello --budget 10` from Telegram. The human reviewed every task before it entered the pipeline.

**The skill file** (`nightcrawler/skills/nightcrawler-planning/SKILL.md`):

Teaches the repo agent:
- **TASK_QUEUE.md format**: The exact header regex Nightcrawler parses (`#### <ID> [status] <title>`)
- **Status markers**: `[ ]` queued, `[x]` done, `[~]` in-progress, `[🚧]` manual/skip
- **Task sizing**: Each task should be completable in one Nightcrawler session (~20-30 min of agent time). If it touches more than ~5 files or has multiple independent concerns, split it.
- **Acceptance criteria**: Must be specific and testable — Nightcrawler uses them literally in its planning and review prompts. Vague criteria → vague implementations.
- **Dependencies**: Reference task IDs. Nightcrawler won't start a task until all deps are `[x]`.
- **MANUAL markers**: Tasks that need secrets, external services, human design decisions, or deployment get `[🚧]`. Nightcrawler skips them automatically.
- **ID convention**: `<PREFIX>-<NNN>` where prefix comes from existing tasks. Continue from highest existing ID.
- **Phases**: Optional `## Phase N: <name>` headers for grouping. Nightcrawler doesn't parse these — they're for human readability.
- **What makes a good task vs a bad task**: Examples of both.

**Implementation:**

1. Create `skills/nightcrawler-planning/SKILL.md` in the nightcrawler repo (template)
2. `nightcrawler-init.sh` copies it into the project's `.claude/skills/` during onboarding
3. Skill is `user-invocable: false` — Claude auto-loads it when task planning is relevant
4. ~80 lines of skill content (format spec + examples + guidelines)

**Deployment per project:**
- `nightcrawler-init.sh` already creates `.nightcrawler/` config — extend it to also copy the skill
- `start.sh` already syncs `.nightcrawler/CLAUDE.md` → `.claude/CLAUDE.md` — add skill copy too
- Or: just include it in the project's `.claude/skills/` directly during init (simpler)

**What this is NOT:**
- Not an autonomous planner — you're in the conversation, you decide what ships
- Not a Telegram command — it runs where you're already working (Claude Code)
- Not a replacement for thinking about your product — it's a formatting assistant that knows the pipeline

### 1.2 Auto-PR after session

**Why:** After a Nightcrawler session, you currently `git pull` on the VPS, inspect commits, and manually merge. A PR gives you a proper diff view, CI checks, and a one-click merge button — all from your phone.

**How it works:**

At the end of each session (in `nightcrawler.sh`, after the task loop), if at least one task was completed:

1. Push `nightcrawler/dev` to origin (already happens — `git push origin nightcrawler/dev`)
2. Check if an open PR already exists for `nightcrawler/dev → main`
   - `gh pr list --head nightcrawler/dev --state open --json number`
3. If no open PR: create one
   ```bash
   gh pr create \
     --base main \
     --head nightcrawler/dev \
     --title "🕷️ Nightcrawler: ${COMPLETED_COUNT} tasks completed" \
     --body "$(generate_pr_body)"
   ```
4. If PR already exists: update the body with new session results
   ```bash
   gh pr edit $PR_NUMBER --body "$(generate_pr_body)"
   ```
5. Send Telegram notification with PR link

**PR body template:**
```markdown
## 🕷️ Nightcrawler Session Report

### Completed Tasks
- [x] CAM-015: Add billing schema — abc1234
- [x] CAM-016: Create Stripe webhook handler — def5678

### Session Stats
- Duration: 2h 15m
- Prompts used: 12/20
- Build: ✅ passing
- Tests: ✅ 45/45

### Remaining Queue
- [ ] CAM-017: Add subscription UI
- [ ] CAM-018: Add usage tracking

---
*Auto-generated by Nightcrawler. Review the diff, then merge when ready.*
```

**Implementation:**
- New function in `nightcrawler.sh`: `create_or_update_pr()`
- Requires `gh` CLI installed and authenticated on VPS (add to `nightcrawler-setup.sh` prerequisites)
- Non-fatal: if PR creation fails (no gh, no auth, no network), log warning and continue
- ~40 lines in nightcrawler.sh + PR body generator

**Prerequisite:** `gh auth login` on VPS. Add to `nightcrawler-setup.sh` step 7.

---

## Tier 2: Observability & Recovery

### 2.1 Smarter failure notifications

**Current:** When a task fails/locks, Telegram gets a generic "🔒 LOCKED" message. You have to SSH in and read logs to understand what happened.

**After:** Structured failure reports via Telegram with enough context to decide next steps from your phone.

**Format:**
```
🔒 CAM-017 locked after 3 plan iterations

TASK: Add subscription UI component
PHASE: Planning (audit rejected 3x)
FEEDBACK THEME: "Missing error handling for expired subscriptions"
LAST CODEX FEEDBACK (summary): Plan doesn't address edge case
  where subscription expires mid-session. Need explicit handling.

OPTIONS:
- Reply `skip CAM-017` to move on
- Reply `note CAM-017 handle expiry in a separate task` to leave guidance
- Edit TASK_QUEUE.md to add acceptance criteria, then `start camello`
```

The information is all already in the session journal — just surface it in the notification instead of making you SSH in to figure out why.

**Implementation:**
- Enhance `escalate()` function in nightcrawler.sh
- Extract last Codex feedback from the journal/review output
- Summarize the failure theme (what the auditor/reviewer actually said)
- Include actionable options in the message
- ~30 lines of changes to existing escalation logic

### 2.2 Session dashboard

**Current:** `status`, `log`, `progress` are separate commands. No at-a-glance view.

**After:** A static HTML page generated after each session (or live-updated during). Shows: current task, pipeline stage, cost so far, completed tasks with diffs, locked tasks with reasons. Serve it on the VPS with a one-liner caddy/nginx config. Way better than tailing logs or waiting for Telegram pings.

```
🕷️ Nightcrawler Dashboard — camello
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ACTIVE: camello (PID 51234, 47min)
BRANCH: nightcrawler/dev (+3 commits ahead of main)

CURRENT TASK: CAM-016 — Create Stripe webhook handler
  Phase: Implementation (iteration 1/5)
  Status: Codex reviewing...

SESSION:
  ✅ CAM-015: Add billing schema (12min)
  🔄 CAM-016: Create Stripe webhook handler (in progress)
  ⏳ CAM-017: Add subscription UI (queued)

BUDGET: 8/20 prompts used (40%)
BUILD: ✅ passing | TESTS: 45/45
```

**Implementation:**
- New script: `scripts/nightcrawler-dashboard.sh` — generates HTML from session data
- Reads from: status file, session journal, budget tracker, git log
- HTML output to `/var/www/nightcrawler/index.html` (or similar)
- Optionally: live-refresh via a cron or inotifywait that regenerates on journal writes
- Also expose as a Telegram command (`dashboard`) for text-only summary
- ~120 lines (HTML generator + text fallback)

### 2.3 `nightcrawler history` command

Show past session summaries without SSHing in:

```
history camello
```

Returns:
```
📜 Last 5 sessions for camello:

1. 20260307-023000 — 3 tasks completed, 0 blocked (47min, 8 prompts)
2. 20260306-220000 — 5 tasks completed, 1 locked (2h, 15 prompts)
3. 20260306-030000 — 2 tasks completed, 2 dep-blocked (35min, 6 prompts)
```

**Implementation:**
- New script: `scripts/nightcrawler-history.sh`
- Reads session directories + journals
- ~60 lines

---

## Tier 3: Integration & Scaling

### 3.1 GitHub Issues → TASK_QUEUE sync

**Why:** Your dev friends don't need to learn the TASK_QUEUE.md markdown format. They write GitHub Issues like they normally would — with a `nightcrawler` label. A sync script converts them to the right format.

**How:** A script (run manually or as a cron/webhook) that reads labeled GitHub Issues and appends them to TASK_QUEUE.md:

```bash
bash scripts/nightcrawler-sync-issues.sh camello --label nightcrawler
```

- Reads issues via `gh issue list --label nightcrawler --json number,title,body`
- Converts each issue to TASK_QUEUE.md format (generates ID, extracts acceptance criteria from issue body)
- Appends to TASK_QUEUE.md (does NOT overwrite existing tasks)
- Marks synced issues with a comment: "Synced to Nightcrawler as CAM-025"
- **Still requires human review** before starting a session — sync just creates entries, you verify them

### 3.2 Spec-to-queue pipeline

**Why:** For greenfield projects, you have a technical spec but no task queue. This is the planning skill on steroids — not just "add billing" but "here's my 50-page spec, decompose it into 40 tasks across 6 phases." Think Camello's `TECHNICAL_SPEC_v1.md` → a full TASK_QUEUE.md in one conversation.

**How:** You're in the repo with the planning skill loaded. You point the agent at your spec:

```
You: "Read TECHNICAL_SPEC_v1.md and generate the full task queue for the project."
```

The agent reads the spec, breaks it into phases, generates tasks with acceptance criteria and dependencies, flags MANUAL items. You review the whole thing, iterate, commit. Same skill, bigger input.

### 3.3 Parallel project orchestration

**Current:** Multiple projects run in parallel but are completely independent. No coordination.

**After:** A `nightcrawler run-all` command that starts sessions for all registered projects with staggered starts (to avoid rate limit contention on shared Max subscription):

```
run-all --budget 10
```

- Iterates registered projects
- Starts each with 60-second stagger
- Monitors all sessions, reports aggregate status
- Stops all on `stop`

---

## Implementation Order

| Phase | Feature | Risk | Effort | Depends on |
|-------|---------|------|--------|------------|
| 1 | Planning skill (SKILL.md template) | Low (new file, no core changes) | ~80 lines | — |
| 2 | Auto-PR | Low (end-of-session addition, non-fatal) | ~80 lines | `gh` on VPS |
| 3 | Smarter failure notifications | Low (enhance existing function) | ~30 lines | — |
| 4 | Dashboard (HTML + text) | Low (new script, read-only) | ~120 lines | — |
| 5 | History command | Low (new script, read-only) | ~60 lines | — |
| 6 | GitHub Issues sync | Medium (external API) | ~100 lines | `gh` on VPS |
| 7 | Spec-to-queue | Zero (same skill, bigger input) | 0 lines | Phase 1 |
| 8 | Parallel orchestration | Medium (coordination logic) | ~120 lines | — |

Phases 1-2 are the priority. Everything else can wait until they're proven.

---

## What Does NOT Change

- **Core pipeline** (`nightcrawler.sh` task loop) — proven with 30+ tasks, don't touch it
- **Codex audit/review** — the independent verification layer stays
- **Human-in-the-loop** — every feature produces proposals, not actions
- **Deterministic bash** — no LLM routing, no AI deciding what to do next
- **Budget system** — prompt caps + Codex dollar caps stay
- **OpenClaw integration** — Telegram control stays

---

## Verification Criteria

### Planning skill is done when:
- [ ] `skills/nightcrawler-planning/SKILL.md` exists in nightcrawler repo (template)
- [ ] `nightcrawler-init.sh` copies skill into project's `.claude/skills/` during onboarding
- [ ] In a project repo, Claude Code can generate tasks in correct TASK_QUEUE.md format when asked
- [ ] Generated tasks have stable IDs, acceptance criteria, dependencies, MANUAL flags
- [ ] Agent knows how to continue from existing task IDs (doesn't restart numbering)

### Auto-PR is done when:
- [ ] Session with ≥1 completed task creates a PR on GitHub
- [ ] PR body has completed tasks, session stats, remaining queue
- [ ] Subsequent sessions update the existing PR (not create duplicates)
- [ ] Failed PR creation doesn't crash the session
