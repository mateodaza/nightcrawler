# Nightcrawler — Improvements for Next Session

## Priority 1 — Fix Before Next Run

### Path consolidation
- `/root/nightcrawler/` and `/home/nightcrawler/nightcrawler/` are duplicates
- Budget scripts default to `/home/nightcrawler/nightcrawler/` but you work from `/root/nightcrawler/`
- We patched it with `NIGHTCRAWLER_STATE_PATH` env var, but should pick ONE canonical path and update all scripts
- **Recommendation:** Move everything to `/home/nightcrawler/nightcrawler/`, update all references, delete `/root/nightcrawler/`

### Codex CLI auth expires
- `codex login --device-auth` stores a token that may expire
- If Nightcrawler hits 401s again mid-session, it'll waste iterations
- **Recommendation:** Add a startup check to NIGHTCRAWLER.md: `codex exec --full-auto "echo ok" 2>&1 | tail -1` — if it fails, notify Mateo immediately instead of burning plan iterations

### `.env` exports
- We added `export` to `OPENAI_API_KEY` but check ALL vars in `/home/nightcrawler/.env` have `export` prefix
- Without `export`, child processes (scripts, codex CLI) don't inherit them

## Priority 2 — Efficiency Gains

### Budget tracking gap
- `budget_gate.sh` wraps script calls, but OpenClaw's own API spend (orchestrator) is untracked
- The $18.20 credit cap covers both, but you have no visibility into the split
- **Recommendation:** After each session, compare `budget.py daily-total` (Nightcrawler scripts) against Anthropic console spend (total) — the difference is OpenClaw overhead

### Codex audit is expensive in iterations, not dollars
- Codex CLI costs $0 per call (billed to your OpenAI account separately)
- But each failed iteration triggers a new Opus plan call ($0.11+)
- 3 rejections = ~$0.35 wasted before skipping
- **Recommendation:** Pre-load more context into the audit prompt — include the Pre-approved Decisions so Codex doesn't flag things Mateo already decided

### Notification batching
- Currently Nightcrawler notifies after EVERY task completion
- If you're asleep, that's a wall of Telegram messages
- **Recommendation:** Add a `--quiet` flag that batches all notifications into the session-end summary

## Priority 3 — Missing Skills/Tools

### No Solidity best practices skill
- Codex has zero custom skills loaded (`~/.codex/skills/` is empty)
- A Foundry/Solidity skill would help Codex produce better audits
- **Recommendation:** Create `~/.codex/skills/solidity-foundry/SKILL.md` with:
  - Foundry project structure conventions
  - OZ v5 import patterns
  - Common Solidity 0.8.24 gotchas
  - Avalanche C-Chain specifics (gas, precompiles)
  - Testing patterns (forge test, fuzz, invariant)

### No rollback skill
- If a task breaks the build and revert fails, Nightcrawler has no recovery protocol beyond `git revert HEAD`
- **Recommendation:** Add a recovery section: if revert fails, `git reset --hard HEAD~1` and notify Mateo

### ClawHub unexplored
- OpenClaw has a `clawhub` skill (package manager for agent skills)
- Run `openclaw skills install clawhub` and browse available skills
- There might be useful coding/git/devops skills already built

## Priority 4 — Quality of Life

### Session resumption
- If OpenClaw session dies mid-task (timeout, crash), there's no resume protocol
- Nightcrawler starts fresh and re-reads TASK_QUEUE.md, but partial work may be uncommitted
- **Recommendation:** Add a startup step: check for uncommitted changes in the clout repo. If found, either commit them as WIP or stash and notify Mateo

### Log consolidation
- Session logs are in `~/nightcrawler/sessions/<id>/`
- But some outputs go to stdout, some to files, some to PROGRESS.md
- **Recommendation:** After each session, auto-generate a `report.md` that aggregates: tasks completed, tasks skipped (with reasons), total spend, git log, and any escalations

### Auto-reload protection
- Currently relies on you NOT enabling auto-reload on Anthropic console
- **Recommendation:** Add a reminder to VPS_CHEATSHEET.md: "CHECK: Anthropic console → Billing → auto-reload is OFF"

## Priority 5 — Cost Optimization (Claude Code Direct)

### Replace Opus planning + Sonnet implementation with Claude Code
- Current pipeline: Opus plans ($0.11/call) → Codex audits ($0) → Sonnet implements ($0.10+/call)
- **Proposed pipeline:** Claude Code plans AND implements ($0 API credits) → Codex audits ($0)
- Savings: eliminates ~$0.20+ per task in API calls
- Claude Code is already available on the VPS and the `coding-agent` skill spawns it
- The task loop would become:
  1. Nightcrawler reads TASK_QUEUE.md, picks next task
  2. Spawns Claude Code with full task context + GLOBAL_PLAN.md as instructions
  3. Claude Code writes the plan, implements, runs forge build && forge test
  4. Nightcrawler calls Codex CLI to audit the diff
  5. If approved → commit + push. If rejected → Claude Code revises.
- **Research needed:**
  - Does Claude Code have its own rate limits or subscription costs?
  - Can it reliably follow GLOBAL_PLAN.md constraints without Opus-level reasoning?
  - How to pass the full task spec + rules as context to `claude -p`
  - Test with one task (NC-002) before switching the full pipeline
- **Claude Max tier decision:**
  - Currently on Max x5 ($100/mo). Consider upgrading to Max x20 ($200/mo)
  - x5 may handle ~5-8 heavy Claude Code sessions per night before throttling
  - x20 comfortably covers 15+ tasks unattended overnight
  - At current API rates, 15 tasks/day = ~$3-5/day in credits ($90-150/mo). x20 at $200/mo flat is cheaper and predictable
  - **Decision:** Check how many tasks Nightcrawler completed overnight with current x5 limits. If it hit the ceiling, upgrade to x20. If not, stay on x5 until we switch to Claude Code direct pipeline

### Keep Opus for complex tasks only
- Some tasks (security-critical, architecture) may still benefit from Opus-level planning
- **Recommendation:** Add a task complexity field to TASK_QUEUE.md (simple/complex)
- Simple → Claude Code direct. Complex → Opus plan + Claude Code implement.

## Priority 6 — Future Scaling

### Multi-project support
- NIGHTCRAWLER.md has a Projects table but everything is hardcoded to clout
- When adding a second project, you'll need to templatize the paths and branch names
- **Recommendation:** When ready, refactor the task loop to read project config from the table dynamically

### Parallel task execution
- Currently tasks run sequentially
- Independent tasks (like NC-015A and NC-015B) could run in parallel via two coding-agent spawns
- **Recommendation:** Not for MVP, but design the task picker to detect parallelizable tasks

### Workspace file version control
- OpenClaw workspace files (`~/.openclaw/workspace/`) are not in git
- If you change NIGHTCRAWLER.md and it breaks, there's no rollback
- **Recommendation:** Symlink `~/.openclaw/workspace/NIGHTCRAWLER.md` → `~/nightcrawler/workspace/NIGHTCRAWLER.md` so changes are git-tracked
