# Nightcrawler

Autonomous implementation orchestrator. Works while you sleep, reports when you wake.

## What This Is

Nightcrawler is a deterministic bash orchestrator that automates the full implementation loop: pick task → plan → audit → implement → review → commit → verify. You define the backlog. Nightcrawler executes it overnight, unsupervised.

## How It Works

```
YOU (day session)                    NIGHTCRAWLER (overnight)
━━━━━━━━━━━━━━━━━━━                 ━━━━━━━━━━━━━━━━━━━━━━━
Define features                      Pick task from queue (LLM)
Set phases & constraints             Plan implementation (Sonnet)
Prioritize task queue                Audit plan (Codex)
Review daily report                  Implement (Sonnet)
Make architecture decisions          Review implementation (Codex)
Approve/reject suggestions           Convergence check (Haiku)
                                     Commit + verify tests
                                     Loop until queue empty
```

## Architecture

The orchestrator is **deterministic bash**. LLMs are only called for creative work.

| Role | Model | Why |
|------|-------|-----|
| Task picking | Claude Sonnet | Dependency-aware, reads queue + git log |
| Planning | Claude Sonnet | Best cost/quality for implementation plans |
| Audit | Codex CLI | Independent perspective on plans |
| Implementation | Claude Sonnet | Best cost/quality for writing code |
| Review | Codex CLI | Independent perspective on code |
| Convergence | Claude Haiku | Fast/cheap loop-stuck detection |

## Budget System

Two-track budget designed for Claude Max subscriptions:

- **`--budget N`** — Max Claude prompts per session (the real constraint on Max). `N=0` means unlimited (run until all tasks done or rate limited).
- **`--codex-cap N`** — Real dollar cap for Codex calls only (default $10). Hitting the cap triggers degraded mode (auto-approve) rather than killing the session.
- **USD cost** tracked as reference metric (API-equivalent), not for enforcement.

## Resilience

- **Codex retry + degrade**: 3 retries on audit/review failure → degraded mode (synthetic approvals) rather than session death
- **Merge conflict softening**: abort and continue on current branch rather than dying
- **Convergence detection**: Haiku detects stuck review loops, caps iterations
- **Skip lists**: stuck tasks get skipped, session continues with remaining work
- **Session journal (WAL)**: crash recovery via append-only JSONL log
- **Post-commit verification**: full test suite after every commit, auto-revert on failure
- **Baseline health check**: records green commit at session start

## Repo Structure

```
nightcrawler/
├── scripts/
│   ├── nightcrawler.sh       ← the orchestrator (deterministic bash)
│   ├── start.sh              ← pre-flight + nohup launcher
│   ├── budget.py             ← cost telemetry (JSONL tracking)
│   ├── call_codex.py         ← Codex CLI/API wrapper
│   └── queue-tasks.sh        ← backlog → queue task management
├── workspace/
│   └── NIGHTCRAWLER.md       ← OpenClaw command dispatcher
├── config/
│   └── ...                   ← model/budget/messaging config
└── templates/
    └── ...                   ← report/queue/plan templates
```

## Usage

From Telegram via OpenClaw:
```
start clout                    # default: 50 prompts, $10 Codex
start clout --budget 100       # 100 prompts
start clout --budget 0         # unlimited — run until done or rate limited
stop                           # graceful stop
status                         # current session state
log                            # last 30 lines of session log
progress                       # project PROGRESS.md
queue                          # pending tasks
alive                          # check if session is running
```

## Proven Results

Round 5 overnight session (Clout project):
- 4 hours unsupervised, $21.86 spent
- +1,326 production LOC, +4,545 test LOC
- 182 tests, all green
- 2 complete smart contracts (CloutEscrow + CloutPool)
- Both audit gates passed, all findings P10+ (minor)

## Infrastructure

Hetzner CX23 (2 vCPU, 4GB RAM) running as dedicated user.
Requires: Claude Code CLI (Max subscription), Codex CLI, project-specific toolchain.
