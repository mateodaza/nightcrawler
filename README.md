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

- A VPS or server (recommended) — or your local machine if you prefer
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) with a Max subscription
- [Codex CLI](https://github.com/openai/codex) (for independent audits/reviews)
- Your project's toolchain (Node, Python, Rust, etc.)

**Where to run it:** A VPS is recommended because sessions run for hours and you don't want your laptop tied up or asleep. A cheap VPS (2 vCPU, 4GB RAM, ~$7/mo) is plenty — Nightcrawler barely uses local compute, it's all API calls. That said, it works fine locally too (just keep your machine awake).

**Cost:** Claude Max subscription ($100/mo for 5x, $200/mo for 20x) covers all Sonnet calls. Codex CLI handles audits/reviews independently. The Max 5x tier works for single-project sessions; 20x is better if you're running multiple projects concurrently (shared rate limits).

### 2. Set Up Nightcrawler

```bash
git clone https://github.com/mateodaza/nightcrawler.git
cd nightcrawler

# Interactive bootstrap — checks prerequisites, configures API keys,
# sets up Claude/Codex CLIs, Telegram bot, and OpenClaw (optional)
bash scripts/nightcrawler-setup.sh
```

The setup script is idempotent (safe to re-run) and never auto-installs system packages — it tells you what's missing and lets you install it yourself. It walks through:

1. **Prerequisites** — git, python3, node, PyYAML
2. **API keys** — prompts for ANTHROPIC_API_KEY, OPENAI_API_KEY (saved to `~/.env`)
3. **Claude Code CLI** — checks install + auth
4. **Codex CLI** — checks install
5. **Telegram bot** — configures token + chat ID, sends test message
6. **OpenClaw** (optional) — deploys workspace files, creates systemd service

Or set up manually:

```bash
# Add your API keys
cat > ~/.env << 'EOF'
ANTHROPIC_API_KEY=your-anthropic-key
TELEGRAM_BOT_TOKEN=your-bot-token
TELEGRAM_CHAT_ID=your-chat-id
OPENAI_API_KEY=your-openai-key
EOF
chmod 600 ~/.env
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

**`.nightcrawler/CLAUDE.md`** — project context for the LLM (copied to `.claude/CLAUDE.md` by start.sh before each session):
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

Nightcrawler auto-creates a `nightcrawler/dev` branch, works there, and attempts to push after each verified task (non-fatal if push fails). You merge to main when ready.

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

Designed for Claude Max subscriptions:

- **`--budget N`** — Max Claude prompts per session. `N=0` = unlimited (run until done or rate limited).
- Codex CLI runs independently for audits/reviews. If Codex is unavailable, the session continues in degraded mode (auto-approves) rather than stopping.

## Recommended Config

For your first run, start small and scale up:

| Setting | First run | Overnight | Why |
|---------|-----------|-----------|-----|
| `--budget` | `5` | `0` (unlimited) | Start small to verify your task queue and config. Once it works, let it run until done. |
| Max tier | 5x ($100/mo) | 20x ($200/mo) | 5x works for one project. 20x if running multiple projects or long overnight sessions. |

**Tips:**
- Always do a `--dry-run` first to catch config issues (wrong build command, missing deps, dirty worktree).
- Write specific acceptance criteria in your tasks — vague criteria produce vague implementations.
- Keep `.nightcrawler/CLAUDE.md` concise (<80 lines). It's injected into every prompt; bloated context wastes tokens.
- The first task in your queue should have no unmet dependencies so Nightcrawler can start immediately.

## Resilience

- **Crash recovery**: Append-only journal (JSONL) enables session resume after crashes
- **Codex retry + degrade**: 3 retries → degraded mode (synthetic approvals), session continues
- **Skip lists**: Stuck tasks get skipped, remaining work continues
- **Post-commit verification**: Full build + test after every commit, auto-revert on failure
- **Baseline health check**: Records last-known-green commit at session start
- **Ghost commit guard**: Blocks commits that only touch bookkeeping files (no real code)
- **Convergence detection**: Caps iteration loops when feedback repeats

## Telegram Control (OpenClaw)

[OpenClaw](https://github.com/nichochar/openclaw) is a Telegram bot framework that lets you control your server from your phone. It's optional — you can always SSH in and run `start.sh` directly — but recommended because it turns session management into quick messages instead of SSH sessions. Start a run from bed, check status from your phone, get notifications when tasks complete or hit blockers.

Setup is handled by `nightcrawler-setup.sh` (step 6). Once configured, you can message your bot:

```
start <project> --budget N     Start a session
stop                           Graceful stop after current task
status                         Current session state
log                            Last 30 lines of session log
progress                       Project PROGRESS.md
queue                          Pending tasks
alive                          Check if session is running
```

Notifications route to per-project Telegram topics when `TELEGRAM_THREAD_ID` is set. With Topics enabled on your Telegram group, each project gets its own thread — no notification noise across projects.

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

# Scripted setup (no prompts)
bash scripts/nightcrawler-init.sh --non-interactive \
    --path /path/to/project --name my-api --branch main

# Update config after stack changes (shows current vs detected)
bash scripts/nightcrawler-init.sh --update /path/to/project

# Preview workspace changes before applying
bash scripts/generate-workspace.sh --diff

# Remove a project
bash scripts/nightcrawler-remove.sh my-api
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
│   ├── nightcrawler-setup.sh    # VPS bootstrap (prerequisites, keys, services)
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
