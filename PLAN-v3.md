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

**What it is:** A `.nightcrawler/skills/` file that lives in each project repo (synced to `.claude/skills/` by `start.sh`). When you're chatting with the project's Claude Code agent, the skill teaches it how Nightcrawler works — the TASK_QUEUE.md format, how to size tasks, how to write acceptance criteria, the dependency system, status markers, everything. The agent becomes your planning partner.

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

1. Create `skills/nightcrawler-planning/SKILL.md` in the nightcrawler repo (master template)
2. `nightcrawler-init.sh` copies it into the project's `.nightcrawler/skills/` during onboarding (repo-owned, source-controlled)
3. `start.sh` syncs `.nightcrawler/skills/` → `.claude/skills/` on every session start (same pattern as `.nightcrawler/CLAUDE.md` → `.claude/CLAUDE.md`)
4. Skill is `user-invocable: false` — Claude auto-loads it when task planning is relevant
5. ~80 lines of skill content (format spec + examples + guidelines)

**Why `.nightcrawler/skills/` not `.claude/skills/` directly:** `start.sh` treats `.claude/` as generated output — it overwrites settings.json and CLAUDE.md on every run. Putting the skill in `.nightcrawler/skills/` keeps it repo-owned and source-controlled. `start.sh` copies it to `.claude/skills/` at session start, same as everything else.

**What this is NOT:**
- Not an autonomous planner — you're in the conversation, you decide what ships
- Not a Telegram command — it runs where you're already working (Claude Code)
- Not a replacement for thinking about your product — it's a formatting assistant that knows the pipeline

### 1.2 `nightcrawler update` — single command to sync everything

**Problem:** Right now, deploying a Nightcrawler update to the VPS is fragile and manual:
```bash
cd /root/nightcrawler
git pull
bash scripts/generate-workspace.sh    # easy to forget
bash scripts/deploy-workspace.sh      # easy to forget
# oh wait, did I need to re-run nightcrawler-init.sh --update for my projects?
# did I need to /new in Telegram to reload?
```

Miss a step and things silently break — stale workspace, wrong permissions, old prompts. This bit us multiple times already.

**After:** One command does everything:
```bash
nightcrawler update
```

Or from Telegram:
```
update
```

**What it does (in order):**

1. `cd /root/nightcrawler && git pull` — pull latest nightcrawler code
2. `generate-workspace.sh` — rebuild NIGHTCRAWLER.md from project registry
3. `deploy-workspace.sh` — copy to `~/.openclaw/workspace/`
4. For each registered project: sync skill templates to `.nightcrawler/skills/`
5. Print summary of what changed
6. Remind to `/new` in Telegram (or auto-restart OpenClaw service if safe)

**The script:** `scripts/nightcrawler-update.sh` (~60 lines)

```bash
#!/usr/bin/env bash
# nightcrawler-update.sh — Pull + regenerate + deploy in one shot
set -euo pipefail

NC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "🕷️ Nightcrawler — Updating..."

# 1. Pull latest
echo "→ Pulling latest..."
git -C "$NC_ROOT" pull

# 2. Regenerate workspace
echo "→ Regenerating workspace..."
bash "$NC_ROOT/scripts/generate-workspace.sh"

# 3. Deploy to OpenClaw
echo "→ Deploying workspace..."
bash "$NC_ROOT/scripts/deploy-workspace.sh"

# 4. Sync project skills/templates
YAML="$NC_ROOT/config/openclaw.yaml"
if [[ -f "$YAML" ]] && python3 -c "import yaml" 2>/dev/null; then
    PROJECTS=$(python3 -c "
import yaml
with open('$YAML') as f:
    data = yaml.safe_load(f) or {}
projects = data.get('projects', {}) or {}
for name, info in projects.items():
    print(f\"{name}|{info.get('path', '')}\")
")
    while IFS='|' read -r name path; do
        [[ -z "$path" ]] && continue
        # Sync planning skill template to repo-owned location (start.sh copies to .claude/skills/)
        if [[ -d "$NC_ROOT/skills/nightcrawler-planning" ]] && [[ -d "$path" ]]; then
            mkdir -p "$path/.nightcrawler/skills/nightcrawler-planning"
            cp "$NC_ROOT/skills/nightcrawler-planning/SKILL.md" \
               "$path/.nightcrawler/skills/nightcrawler-planning/SKILL.md" 2>/dev/null && \
                echo "  ✓ $name: planning skill synced" || true
        fi
    done <<< "$PROJECTS"
fi

echo ""
echo "✅ Update complete. Run /new in Telegram to reload workspace."
```

**Workspace command:**
```
- `update` → exec: `bash /root/nightcrawler/scripts/nightcrawler-update.sh`
```

**Why this matters for open-source:** When you share Nightcrawler with friends, the update flow has to be bulletproof. "Run `nightcrawler update` after pulling" is one thing to remember. "Run these 4 scripts in this order from this directory" is where people give up.

**Future:** Could add a git post-merge hook that auto-runs `nightcrawler-update.sh` so even `git pull` alone does the right thing. But explicit is better than magic for v1.

### 1.3 Auto-PR after session

**Why:** After a Nightcrawler session, you currently `git pull` on the VPS, inspect commits, and manually merge. A PR gives you a proper diff view, CI checks, and a one-click merge button — all from your phone.

**How it works:**

At the end of each session (in `nightcrawler.sh`, after the task loop), if at least one task was completed:

1. Push `nightcrawler/dev` to origin (already happens — `git push origin nightcrawler/dev`)
2. Verify remote branch parity before touching PR state:
   - Resolve local HEAD: `git rev-parse HEAD`
   - Resolve remote head: `git ls-remote origin refs/heads/nightcrawler/dev`
   - If mismatch: warn and skip PR create/edit for this session (non-fatal)
3. Check if an open PR already exists for `nightcrawler/dev → $BASE_BRANCH`
   - `gh pr list --head nightcrawler/dev --state open --json number`
   - `BASE_BRANCH` comes from project config (openclaw.yaml `base_branch`, defaults to `main`)
4. If no open PR: create one
   ```bash
   gh pr create \
     --base "$BASE_BRANCH" \
     --head nightcrawler/dev \
     --title "🕷️ Nightcrawler: ${COMPLETED_COUNT} tasks completed" \
     --body "$(generate_pr_body)"
   ```
5. If PR already exists: update the body with new session results
   ```bash
   gh pr edit $PR_NUMBER --body "$(generate_pr_body)"
   ```
6. Send Telegram notification with PR link

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
- Non-fatal: if remote `nightcrawler/dev` does not match local HEAD, skip PR update and warn
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
| 2 | `nightcrawler update` (single sync command) | Low (wraps existing scripts) | ~60 lines | — |
| 3 | Auto-PR | Low (end-of-session addition, non-fatal) | ~80 lines | `gh` on VPS |
| 4 | Smarter failure notifications | Low (enhance existing function) | ~30 lines | — |
| 5 | Dashboard (HTML + text) | Low (new script, read-only) | ~120 lines | — |
| 6 | History command | Low (new script, read-only) | ~60 lines | — |
| 7 | GitHub Issues sync | Medium (external API) | ~100 lines | `gh` on VPS |
| 8 | Spec-to-queue | Zero (same skill, bigger input) | 0 lines | Phase 1 |
| 9 | Parallel orchestration | Medium (coordination logic) | ~120 lines | — |

Phases 1-3 are the priority. Everything else can wait until they're proven.

---

## Operational Guarantees (for v3 rollout)

### Rollout controls (kill switches)

Every Tier 1 feature ships behind an env flag. Default is OFF until smoke tests pass.

| Feature | Flag | Default |
|---------|------|---------|
| Planning skill sync | `NC_ENABLE_SKILL_SYNC` | `0` |
| `nightcrawler update` command | `NC_ENABLE_UPDATE_CMD` | `0` |
| Auto-PR | `NC_ENABLE_AUTO_PR` | `0` |
| Enhanced failure notifications | `NC_ENABLE_RICH_ALERTS` | `0` |

Rollout process:
- Enable per project first (camello, then clout), not globally.
- Promote to default ON only after 3 clean sessions per project.
- Any regression: flip flag to `0` and continue normal pipeline (no rollback required).

### Failure policy matrix (fatal vs non-fatal)

| Component | Failure behavior |
|-----------|------------------|
| Planning skill sync | Warn and continue session startup |
| `nightcrawler update` git pull fails | Fatal for update command only; no partial deploy |
| `generate-workspace.sh` fails during update | Fatal for update command only |
| Workspace deploy fails during update | Warn and continue (scripts still updated) |
| Auto-PR create/edit fails | Warn, continue session completion |
| Rich alert formatting fails | Fallback to current plain alert format |

Rule: Tier 1 features must never fail the core task loop unless explicitly marked fatal above.

### Security and trust boundaries

- Telegram/OpenClaw remains command-dispatch only; no free-form shell execution.
- High-impact write commands (`update`, future `run-all`, `remove`) must be explicit and non-ambiguous.
- `status`/`alive` remain lock-first live checks.
- Credentials remain in `~/.env`; scripts can read/update known keys only.
- No feature in this plan bypasses Codex audit/review gates in normal mode.

### Idempotency contract

- `nightcrawler update` is safe to run repeatedly: pull, regenerate, deploy, sync templates.
- Skill sync overwrites template targets deterministically (source of truth is `nightcrawler/skills/` + project `.nightcrawler/skills/`).
- Auto-PR is idempotent: create once, then edit existing PR body.
- Setup/bootstrap scripts are re-runnable and must skip already-configured steps.

### Smoke-test matrix (minimum)

| Feature | Happy path | Failure path |
|---------|------------|--------------|
| Planning skill sync | Skill appears in project `.nightcrawler/skills/` and is copied to `.claude/skills/` on start | Missing template dir logs warning, startup still succeeds |
| `nightcrawler update` | Pull + regen + deploy + skill sync completes with summary | Empty/null YAML handled (`or {}`), command exits cleanly |
| Auto-PR | Completed session creates/updates PR against `$BASE_BRANCH` | `gh` missing/auth fails logs warning, session still completes |
| Rich alerts | Locked task sends structured alert with actionable options | Journal parse failure falls back to existing plain alert |

### Success metrics (30-day)

- Update reliability: >= 95% successful `nightcrawler update` runs without manual fixes.
- PR automation: >= 90% of sessions with completed tasks produce/create-or-update PR successfully.
- Alert usefulness: >= 80% of lock events resolved without SSHing into VPS logs.
- Regression guard: 0 incidents where Tier 1 features break core task loop execution.

### Drift guards (prevent stale generated artifacts)

- `generate-workspace.sh --diff` must be clean before merge.
- Add a CI check that regenerates `workspace/NIGHTCRAWLER.md` and fails if git diff is non-empty.
- Shell/Python sanity gates on every PR: `bash -n scripts/*.sh` and `python3 -m compileall scripts`.
- `status`/`alive` behavior is contract-locked: lock-held check first, marker second, no status-file fallback.

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
- [ ] `nightcrawler-init.sh` copies skill into project's `.nightcrawler/skills/` during onboarding
- [ ] In a project repo, Claude Code can generate tasks in correct TASK_QUEUE.md format when asked
- [ ] Generated tasks have stable IDs, acceptance criteria, dependencies, MANUAL flags
- [ ] Agent knows how to continue from existing task IDs (doesn't restart numbering)

### `nightcrawler update` is done when:
- [ ] `nightcrawler update` from VPS or Telegram pulls + regenerates + deploys in one command
- [ ] Skill templates sync to all registered projects
- [ ] Summary shows what changed
- [ ] Works from any directory (script resolves its own root)

### Auto-PR is done when:
- [ ] Session with ≥1 completed task creates a PR on GitHub
- [ ] PR body has completed tasks, session stats, remaining queue
- [ ] Subsequent sessions update the existing PR (not create duplicates)
- [ ] Failed PR creation doesn't crash the session
- [ ] If remote `nightcrawler/dev` != local HEAD, PR create/edit is skipped with warning (no stale PR body update)

### Feature flags are done when:
- [ ] `NC_ENABLE_SKILL_SYNC=0` disables skill sync; `1` enables it
- [ ] `NC_ENABLE_UPDATE_CMD=0` hides/disables `update`; `1` enables it
- [ ] `NC_ENABLE_AUTO_PR=0` disables PR create/edit; `1` enables it
- [ ] `NC_ENABLE_RICH_ALERTS=0` keeps plain alerts; `1` enables structured alerts
- [ ] With all flags at `0`, core Nightcrawler task loop behavior is unchanged

### Dispatcher/live-state model is done when:
- [ ] `status` returns active session when lock is held even if marker is absent (startup window)
- [ ] `alive` distinguishes: lock-held active, marker-only stale/starting, neither = no active session
- [ ] `log/progress/queue/branch` may fall back to most recent project
- [ ] `workspace/NIGHTCRAWLER.md` always matches `generate-workspace.sh` output (no manual drift)
