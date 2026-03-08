# Nightcrawler

Autonomous coding agent that executes your backlog overnight. You define the tasks, it plans, implements, reviews, and commits — unsupervised.

> **If you've used Claude Code's [`/loop`](https://code.claude.com/docs/en/scheduled-tasks) and want to go further:** `/loop` polls a deploy or babysits a PR inside a single session. Nightcrawler runs a full pipeline — plan → independent audit → implement → independent review → commit → verify — across your entire backlog, unattended, overnight. Different scope, same intuition: your codebase should move while you sleep.

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
- [OpenClaw](https://github.com/nichochar/openclaw) (optional locally; required for full mobile Telegram automation)
- Your project's toolchain (Node, Python, Rust, etc.)

**Where to run it:** A VPS is recommended because sessions run for hours and you don't want your laptop tied up or asleep. Nightcrawler barely uses local compute — the heavy lifting is done by the LLMs — so a cheap VPS (2 vCPU, 4GB RAM) is plenty. We run on [Hetzner](https://www.hetzner.com/cloud/) (~€4/mo for CX22) and recommend it for the price. Any provider works though — see the [OpenClaw VPS guide](https://docs.openclaw.ai/vps) for options including Railway, Fly.io, Oracle Cloud (free tier), and others. It also works fine locally (just keep your machine awake).

**Cost:** Claude Max subscription ($100/mo for 5x, $200/mo for 20x) covers Sonnet calls. Codex CLI ($20/mo) handles audits and reviews, with API fallback available; keep `--codex-cap` set to bound metered fallback spend. The Max 5x tier works for single-project sessions; 20x is better if you're running multiple projects concurrently (shared rate limits).

### 2. Set Up Nightcrawler

```bash
git clone https://github.com/mateodaza/nightcrawler.git
cd nightcrawler

# Interactive bootstrap — checks prerequisites, configures API keys,
# sets up Claude/Codex CLIs, Telegram bot, and OpenClaw
bash scripts/nightcrawler-setup.sh
```

The setup script is idempotent (safe to re-run) and never auto-installs system packages — it tells you what's missing and lets you install it yourself. It walks through:

1. **Prerequisites** — git, python3, node, PyYAML
2. **API keys** — prompts for ANTHROPIC_API_KEY, OPENAI_API_KEY (saved to `~/.env`)
3. **Claude Code CLI** — checks install + auth
4. **Codex CLI** — checks install
5. **Telegram bot** — configures token + chat ID, sends test message
6. **OpenClaw** — deploys workspace files, creates systemd service (needed for Telegram control)

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
BUILD_CMD="pnpm build"
TEST_CMD="pnpm type-check"
INSTALL_CMD="pnpm install"
DEPS_CHECK="test -d node_modules"
TOOLS="node pnpm"
TOOLS_ALLOW="node pnpm"
TELEGRAM_THREAD_ID="24"   # optional — routes to a Telegram topic
# PROJECT_DESC is optional/manual (used for richer planning prompts)
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
# Dry run (runs planning/audit, then stops before implementation/commit)
bash scripts/start.sh myproject --budget 5 --dry-run

# Real session
bash scripts/start.sh myproject --budget 20

# Or from Telegram via OpenClaw
start myproject --budget 20
```

Nightcrawler auto-creates a `nightcrawler/dev` branch, works there, and pushes after each verified task. To keep everything local (no pushes), add `NC_AUTO_PUSH=0` to your project's `.nightcrawler/config.sh`. Push failures are always non-fatal — the session continues either way.

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
- **`--codex-cap N`** — Cap on metered Codex spend for API fallback (default `$10`). If Codex is unavailable, the session continues in degraded mode (auto-approves) rather than stopping.

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

[OpenClaw](https://github.com/nichochar/openclaw) is a Telegram bot framework that lets you control your server from your phone. Start a run from bed, check status from your phone, get notifications when tasks complete or hit blockers.

**Setup:** You need a Telegram bot token and your chat ID. If you don't have one yet:

1. Message [@BotFather](https://t.me/BotFather) on Telegram → `/newbot` → save the token
2. Get your chat ID by messaging your bot then running `curl "https://api.telegram.org/bot<token>/getUpdates"` — look for `from.id`
3. Run `nightcrawler-setup.sh` — it will prompt for both values and send a test message

Full walkthrough: [OpenClaw Telegram docs](https://docs.openclaw.ai/telegram)

OpenClaw is required for mobile/Telegram automation; if you run locally from terminal only, you can skip it. Once configured, you can message your bot:

```
start <project> --budget N     Start a session
stop                           Graceful stop after current task
status                         Current session state
log                            Last 30 lines of session log
progress                       Project PROGRESS.md
queue                          Pending tasks
alive                          Check if session is running
```

**Recommended: use a Telegram group with Topics enabled.** DMs work for a single project, but once you're running multiple projects you want notifications separated. Create a group, add your bot, enable Topics (group settings → Topics), then create a topic per project. Set `TELEGRAM_THREAD_ID` in each project's `.nightcrawler/config.sh` to route notifications to the right thread — keeps each project's noise in its own lane.

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
│   ├── call_codex.py            # Codex CLI wrapper (API fallback)
│   └── budget.py                # cost telemetry (JSONL tracking)
├── workspace/
│   └── NIGHTCRAWLER.md          # OpenClaw command dispatcher (auto-generated)
├── config/
│   └── openclaw.yaml            # registered projects + paths
├── RULES.md                     # safety + operational rules
└── sessions/                    # session logs + reports (auto-generated)
```

## Troubleshooting

**Claude Code CLI auth:** The CLI uses your Max subscription, not the API key. Run `claude login` and authenticate with your Anthropic account. `ANTHROPIC_API_KEY` in `~/.env` is used by other parts of the pipeline but the CLI itself prefers subscription auth.

**Codex CLI auth:** Codex stores its credentials at `~/.codex/config.json`. Run `codex` once interactively to authenticate. If Codex is unavailable during a session, Nightcrawler continues in degraded mode (auto-approves audits/reviews) rather than stopping.

**Git push from VPS:** Nightcrawler pushes to `nightcrawler/dev` after each task. On a VPS, you need SSH keys set up for your Git remote. We recommend [GitHub's SSH setup guide](https://docs.github.com/en/authentication/connecting-to-github-with-ssh) — generate a key on the VPS, add it to your GitHub account, and switch your remote to SSH (`git remote set-url origin git@github.com:user/repo.git`). Alternatively, set `NC_AUTO_PUSH=0` in your project's config to keep commits local and pull them from another machine.

**Rate limits:** Claude Max has undocumented rate limits (token-weighted, not pure message count). If you hit them, the session pauses and retries automatically. The 5x tier ($100/mo) works for single-project sessions; 20x ($200/mo) is better for long overnight runs or multiple projects.

**Stale workspace:** If Telegram commands stop working after a `git pull`, you probably need to regenerate and redeploy the OpenClaw workspace:
```bash
bash scripts/generate-workspace.sh
bash scripts/deploy-workspace.sh
```
Then send `/new` in Telegram to reload.

**OpenClaw not picking up env vars:** OpenClaw runs as a systemd service and doesn't inherit your shell environment. API keys must be in `~/.env` — the pipeline loads them explicitly via `_load_env()`. If you added a key to `.bashrc` or `.zshrc`, it won't be visible to Nightcrawler.

## Proven Results

**Clout** (Solidity/Foundry + Next.js):
- 30 tasks completed across 6 sessions
- 182 tests, all passing
- Full smart contract suite + React frontend
- Independent Codex audit on every plan and implementation
- Zero manual intervention during overnight runs

**Camello** (Next.js 15 + Hono/tRPC monorepo):
- Second project onboarded — different stack, same pipeline
- Autonomous commits on a TypeScript monorepo (Drizzle, Turborepo)
- Zero changes to the orchestrator to support a new stack
