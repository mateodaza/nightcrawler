# Nightcrawler

Autonomous implementation orchestrator. Works while you sleep, reports when you wake.

## What This Is

Nightcrawler is the configuration and state repo for an OpenClaw-based orchestrator that automates the implementation loop for your projects. You define the plan. Nightcrawler executes it.

## How It Works

```
YOU (day session)                    NIGHTCRAWLER (overnight)
━━━━━━━━━━━━━━━━━━━                 ━━━━━━━━━━━━━━━━━━━━━━━
Define features                      Pick task from queue
Set phases & constraints             Mini-plan (Opus)
Prioritize task queue                Audit mini-plan (Codex)
Review daily report                  Implement (Sonnet)
Make architecture decisions          Review implementation (Codex)
Approve/reject suggestions           Loop until approved
Update global plan                   Commit + update progress
                                     Generate daily report
```

## Repo Structure

```
nightcrawler/
├── README.md                 ← you are here
├── SPEC.md                   ← full orchestrator specification (v2)
├── TERMS.md                  ← consolidated glossary
├── RULES.md                  ← safety constraints (orchestrator + project layers)
├── ESCALATION.md             ← when and how to ping Telegram
├── config/
│   ├── models.yaml           ← model assignments per role
│   ├── budget.yaml           ← spending caps, reserve, alerts
│   └── openclaw.yaml         ← OpenClaw container/messaging config
├── templates/
│   ├── daily_report.md       ← report template (completed vs reverted)
│   ├── task_queue.md         ← task format template (NC-xxx stable IDs)
│   └── mini_plan.md          ← mini-plan format template
├── sessions/                 ← auto-generated per session
│   └── <session-id>/         ← e.g. 20260228-234500-clout
│       ├── journal.jsonl     ← write-ahead log (crash recovery)
│       ├── report.md
│       ├── cost.jsonl
│       ├── decisions.md
│       └── tasks/
│           └── <task-id>/
│               └── mini_plan.md
└── memory.md                 ← orchestrator-level persistent memory
```

## Quick Start

1. Read `SPEC.md` for the full system design
2. Read `RULES.md` for what Nightcrawler can and cannot do
3. Read `ESCALATION.md` for when you'll get Telegram messages
4. Configure `config/` for your project
5. Deploy to Hetzner CX23 with OpenClaw + Claude Code plugin + Codex CLI
6. Add tasks to your project's `TASK_QUEUE.md` using NC-xxx stable IDs
7. Sleep

## Models

| Role | Model | Why |
|------|-------|-----|
| Mini-planning | Claude Opus 4.6 | Best reasoning for implementation approach |
| Implementation | Claude Sonnet 4.6 | Best cost/quality ratio for writing code |
| Audit & review | Codex-mini (CLI or API) | Independent perspective, cheapest for review |
| Reports | Claude Sonnet 4.6 | Structured output, cost-efficient |

## Key Safety Features (v2)

- **Session journal (WAL):** crash recovery via append-only JSONL log
- **Pre-call budget gates:** checks budget BEFORE every model call, not after
- **$2 reserve:** always enough budget for clean session shutdown
- **Subprocess timeouts:** every process has wall-clock + no-output limits
- **Post-commit verification:** full test suite after every commit, auto-revert on failure
- **Baseline health check:** records green commit at session start, blames regressions accurately
- **Lockfile + persistent dev branch:** prevents concurrent sessions, all work on `nightcrawler/dev`
- **Independent audit:** Codex (non-Claude) reviews all plans and code — never substituted

## Cost

Typical overnight session (5-15 tasks): $5-20
Budget cap: configurable per session (default $20, with $2 reserve)
Daily cap: $50 | Monthly cap: $200

## Infrastructure

Hetzner CX23 (2 vCPU, 4GB RAM, Helsinki) running as dedicated `nightcrawler` user.
