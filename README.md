# Nightcrawler

Autonomous coding agent that executes your backlog overnight. You define the tasks, it plans, implements, reviews, and commits — unsupervised.

## How It Works

```
YOU                                 NIGHTCRAWLER
━━━━━━━━━━━━━━━━━━━                 ━━━━━━━━━━━━━━━━━━━━━━━
Write TASK_QUEUE.md                 Pick next task (Sonnet)
Set budget + constraints            Plan implementation (Sonnet)
Go to sleep                         Audit plan (Codex)
                                    Implement code (Sonnet)
Wake up, check Telegram             Review implementation (Codex)
Merge nightcrawler/dev → main       Commit + verify (build + tests)
                                    Loop until queue empty or budget hit
```

The orchestrator is **deterministic bash**. LLMs are only called for creative work (planning, coding, reviewing). All routing, sequencing, retries, and error handling are pure bash.

## Quick Start

### 1. Prerequisites

- A VPS or server (Nightcrawler runs unattended)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) with a Max subscription
- [Codex CLI](https://github.com/openai/codex) (for independent audits/reviews)
- Your project's toolchain (Node, Python, Rust, etc.)

### 2. Set Up Nightcrawler

```bash
git clone https://github.com/mateodaza/nightcrawler.git
cd nightcrawler

# Add your API keys
cat > ~/.env << 'EOF'
TELEGRAM_BOT_TOKEN=your-bot-token
TELEGRAM_CHAT_ID=your-chat-id
OPENAI_API_KEY=your-openai-key
EOF
```

### 3. Onboard a Project

```bash
# Interactive setup — detects stack, creates config, registers project
bash scripts/nightcrawler-init.sh /path/to/your/project
```

This creates two files in your project:

**`.nightcrawler/config.sh`** — build/test commands, tooling:
```bash
PROJECT_DESC="Next.js/TypeScript monorepo"
BUILD_CMD="pnpm build"
TEST_CMD="pnpm type-check"
INSTALL_CMD="pnpm install"
TELEGRAM_THREAD_ID="24"   # optional — routes to a Telegram topic
```

**`.claude/CLAUDE.md`** — project context for the LLM:
```markdown
# My Project — Claude Code Context
## Stack
Next.js 15, TypeScript, Drizzle ORM, tRPC
## Key Conventions
- Use named imports, never wildcard
- All new code must pass type-check
- Reference TECHNICAL_SPEC.md for architecture decisions
```

### 4. Write Your Task Queue

Create `TASK_QUEUE.md` in your project root. Nightcrawler parses this with regex — the header format is strict:

```markdown
# Task Queue — My Project

## Phase 1: Foundation

#### PROJ-001 [x] Initial project setup
Already done.

#### PROJ-002 [ ] Add user authentication
Implement sign-up, login, and logout flows.

**Acceptance Criteria:**
- Sign-up validates email + password (min 8 chars)
- Login sets session cookie
- Protected routes redirect to /login if unauthenticated

**Depends on:** PROJ-001

#### PROJ-003 [ ] Build dashboard layout
**Depends on:** PROJ-002

**Acceptance Criteria:**
- Sidebar with navigation links
- Responsive: collapses on mobile
- Active route highlighted

#### PROJ-004 [🚧] Deploy to production (MANUAL)
Human-only — Nightcrawler skips these automatically.
```

**Status markers:** `[ ]` queued · `[x]` done · `[~]` in-progress · `[🚧]` manual/skip

### 5. Run

```bash
# Dry run (pre-flight only, no LLM calls)
bash scripts/start.sh myproject --budget 5 --dry-run

# Real session
bash scripts/start.sh myproject --budget 20

# Or from Telegram via OpenClaw
start myproject --budget 20
```

Nightcrawler auto-creates a `nightcrawler/dev` branch, works there, and pushes after each task. You merge to main when ready.

## Pipeline

Each task goes through this pipeline:

```
pick_task → plan (Sonnet) → audit (Codex) → implement (Sonnet) → review (Codex) → commit → verify
              ↑                   |               ↑                    |
              └── revise ─────────┘               └── revise ──────────┘
                (max 3 rounds)                      (max 5 rounds)
```

If audit/review rejects, the plan/code is revised. Hard blocks (security issues) lock the task and notify you. Soft rejects iterate up to the cap, then proceed if local verification passes.

## Models

| Role | Model | Why |
|------|-------|-----|
| Task picking | Sonnet | Reads queue + git log, picks next eligible task |
| Planning | Sonnet | Generates implementation plan from task + acceptance criteria |
| Plan audit | Codex | Independent review — catches issues Sonnet misses |
| Implementation | Sonnet | Writes code following the approved plan |
| Code review | Codex | Independent review of the implementation |
| Learning capture | Haiku | Extracts one-line insights after each task |

## Budget

Two-track system designed for Claude Max subscriptions:

- **`--budget N`** — Max Claude prompts per session. `N=0` = unlimited (run until done or rate limited).
- **`--codex-cap N`** — Dollar cap for Codex calls (default $10). Hitting the cap triggers degraded mode (auto-approve) rather than killing the session.

## Resilience

- **Crash recovery**: Append-only journal (JSONL) enables session resume after crashes
- **Codex retry + degrade**: 3 retries → degraded mode (synthetic approvals), session continues
- **Skip lists**: Stuck tasks get skipped, remaining work continues
- **Post-commit verification**: Full build + test after every commit, auto-revert on failure
- **Baseline health check**: Records last-known-green commit at session start
- **Ghost commit guard**: Blocks commits that only touch bookkeeping files (no real code)
- **Convergence detection**: Caps iteration loops when feedback repeats

## Telegram Commands

Via OpenClaw bot:

```
start <project> --budget N     Start a session
stop                           Graceful stop after current task
status                         Current session state
log                            Last 30 lines of session log
progress                       Project PROGRESS.md
queue                          Pending tasks
alive                          Check if session is running
```

Notifications route to per-project Telegram topics when `TELEGRAM_THREAD_ID` is set.

## Multi-Project

Nightcrawler supports multiple projects simultaneously. Each project has its own:
- `.nightcrawler/config.sh` (build/test commands)
- `.claude/CLAUDE.md` (project context)
- `TASK_QUEUE.md` (backlog)
- Lock file, state dir, log file
- Telegram topic (optional)

```bash
# Onboard projects
bash scripts/nightcrawler-init.sh /path/to/project-a
bash scripts/nightcrawler-init.sh /path/to/project-b

# Run both
bash scripts/start.sh project-a --budget 10
bash scripts/start.sh project-b --budget 10

# List registered projects
bash scripts/nightcrawler-list.sh
```

## Repo Structure

```
nightcrawler/
├── scripts/
│   ├── nightcrawler.sh          # the orchestrator (all logic lives here)
│   ├── start.sh                 # pre-flight checks + nohup launcher
│   ├── nightcrawler-init.sh     # interactive project onboarding
│   ├── nightcrawler-list.sh     # list registered projects
│   ├── nightcrawler-remove.sh   # unregister a project
│   ├── generate-workspace.sh    # regenerate OpenClaw workspace
│   ├── deploy-workspace.sh      # deploy workspace to OpenClaw
│   ├── call_codex.py            # Codex CLI/API wrapper
│   └── budget.py                # cost telemetry (JSONL tracking)
├── workspace/
│   └── NIGHTCRAWLER.md          # OpenClaw command dispatcher (auto-generated)
├── config/
│   └── openclaw.yaml            # registered projects + paths
├── RULES.md                     # safety + operational rules
└── sessions/                    # session logs + reports (auto-generated)
```

## Proven Results

First multi-session run (Clout project — Solidity/Foundry):
- 30 tasks completed across 6 sessions
- 182 tests, all passing
- Full smart contract suite + React frontend
- Independent Codex audit on every plan and implementation
- Zero manual intervention during overnight runs
