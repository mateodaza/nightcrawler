# Terms

Consolidated glossary for Nightcrawler. All docs and prompts use these terms consistently.

## Core Concepts

**Global Plan**
Your manually-written master plan for a project. Contains phases, features, constraints, architecture decisions. Lives in the project repo (e.g., `clutch/GLOBAL_PLAN.md`). Nightcrawler reads it. Never writes it. This is your authority — the source of truth for what gets built and why.

**Task Queue**
Ordered list of implementation tasks derived from the Global Plan. You write and prioritize it. Nightcrawler consumes in order, respecting dependencies. Lives in the project repo as `TASK_QUEUE.md`. Tasks use stable IDs (NC-001, NC-002) that never change when reordered.

**Mini-Plan**
Opus's tactical implementation approach for a single task from the queue. Scoped to one feature/fix/component. Gets audited by Codex before any code is written. Persisted to `sessions/<session-id>/tasks/<task-id>/mini_plan.md` for the audit trail.

**Loop**
One full implementation cycle for a single task:
1. Opus writes a mini-plan
2. Codex audits the mini-plan
3. If rejected → Opus revises → back to step 2
4. If approved → Sonnet implements
5. Codex reviews implementation
6. If rejected → Sonnet revises → back to step 5
7. If approved → commit, post-commit verify, update progress, next task

**Lock**
When Opus and Codex cannot converge. Triggers when EITHER: 3 iterations reached (hard cap) OR Jaccard keyword overlap >0.5 across last 3 rejections. Detected by pure string processing — no model judges its own disagreement. Triggers WhatsApp escalation.

**Session**
One overnight run with a unique ID: `<YYYYMMDD>-<HHMMSS>-<project>`. Operates on a dedicated git branch (`nightcrawler/<session-id>`). Starts with lockfile acquisition and baseline health check. Ends with report, cleanup, and lock release.

**Session ID**
Unique identifier for each session: `<YYYYMMDD>-<HHMMSS>-<project>` (e.g., `20260228-234500-clout`). Used for branch name, directory name, lockfile tracking, and all WhatsApp messages.

**Session Journal (WAL)**
Append-only JSONL file (`sessions/<session-id>/journal.jsonl`) that records every state transition. Used for crash recovery — on restart, the orchestrator reads the journal to determine where it left off.

**Baseline**
The last-known-green commit hash recorded at session start after running the full test suite. Used to accurately blame regressions: if pre-flight fails on a subsequent task, compare against baseline to determine if failures are new (previous task broke something) or pre-existing.

**Daily Report**
Auto-generated summary after a session ends. Two halves: project progress (for you — completed, reverted, blocked, locked) and orchestrator insights (for tuning Nightcrawler itself). Lives in `sessions/<session-id>/report.md`.

**Escalation**
Any message sent to WhatsApp requiring your decision. Two priority classes: URGENT (blocking — sent immediately, bypasses rate limits) and NORMAL (notifications — batched in 15-min windows, capped at 5/hour). See ESCALATION.md for the full map.

## Task States

**QUEUED** — Ready for Nightcrawler to pick up.
**IN_PROGRESS** — Currently being worked on by a session.
**COMPLETED** — Committed, post-commit verified (zero failing tests), progress updated.
**BLOCKED** — Needs manual action (external dependency, missing secret, infra issue, etc.). NOT for dependency failures — those use DEP_BLOCKED.
**NEEDS_CLARIFICATION** — Ambiguous spec, escalated to WhatsApp.
**LOCKED** — Opus/Codex disagreement unresolved, needs your decision.
**DEP_BLOCKED** — Dependency is BLOCKED, SKIPPED, or LOCKED, so this task is auto-skipped.
**SKIPPED** — Permanently skipped by your decision.
**MANUAL** — Task executed by Mateo, not Nightcrawler. Orchestrator skips automatically and does not attempt planning, implementation, or audit. MANUAL tasks are NOT dependencies — downstream tasks treat them as if they don't exist in the queue.

## State & Memory

**Orchestrator Memory** (`nightcrawler/memory.md`)
Persistent learnings about model behaviors, recurring patterns, rule adjustments, and cross-project insights. Nightcrawler reads AND writes this. You review and prune it. Max 100 active lines, entries older than 7 days summarized.

**Project Memory** (`<project>/memory.md`)
Context about a specific codebase — decisions made, patterns used, gotchas discovered, architecture conventions. Nightcrawler writes it after each completed task. Max 150 active lines.

**Project Progress** (`<project>/PROGRESS.md`)
Current state of the project against the Global Plan. Updated by Nightcrawler after each task completion.

## Roles

**Planner** — Claude Opus 4.6
Creates mini-plans. Addresses audit feedback. Makes tactical implementation decisions within the constraints of the Global Plan. Never makes architectural decisions — those are yours.

**Implementer** — Claude Sonnet 4.6
Writes code based on an approved mini-plan. Addresses review feedback. Output token cap is dynamic — adjusted based on remaining task budget.

**Auditor** — OpenAI Codex-mini (via Codex CLI or OpenAI API)
Reviews mini-plans and implementations. Independent from Claude models — provides genuine second opinion. Two interfaces: Codex CLI (preferred) and OpenAI API direct (fallback). If both fail, session pauses — never substituted with Claude.

**Orchestrator** — OpenClaw
Routes tasks between models. Detects locks. Manages budget (pre-call enforcement). Sends WhatsApp messages. Generates reports. Maintains session journal. Never writes code or plans — only coordinates.

**You** — Mateo
Writes the Global Plan. Prioritizes the Task Queue. Reviews daily reports. Makes architecture decisions. Resolves locks. Improves Nightcrawler's rules over time.
