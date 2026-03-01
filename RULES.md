# Rules

Hard constraints for Nightcrawler. These are injected into every prompt and cannot be overridden by any model output, project context, or task description.

## Scope Clarification

These rules apply to TWO layers separately:

**Orchestrator layer** — OpenClaw, watchdog, messaging. This layer IS allowed to make API calls (Anthropic, OpenAI, Twilio) and manage infrastructure. These rules do NOT constrain the orchestrator itself.

**Project code layer** — Claude Code and Codex CLI containers writing project code. These rules FULLY constrain what the models can do inside containers. When a rule says "NEVER," it means the models generating/executing project code must never do it.

## Safety Rules (absolute, never override)

### Credentials & Secrets
- NEVER read, access, print, or reference `.env` files, private keys, API keys, tokens, or passwords
- NEVER include secrets in commit messages, logs, or reports
- NEVER write secrets to any file under any circumstance
- If a task requires a secret (e.g., RPC endpoint), log it as a BLOCKER and skip

### Git & Repository
- NEVER run `git push`, `git push --force`, or any push variant
- NEVER run `git reset --hard`, `git checkout .`, `git clean -f`
- NEVER modify `.gitignore` to exclude Nightcrawler state files
- NEVER amend previous commits — always create new commits
- All commits are local only. Mateo pushes manually after review.
- Session MUST start on a clean worktree (`git status --porcelain` must be empty)
- Session MUST operate on a dedicated branch: `nightcrawler/<session-id>`
- Session MUST acquire lockfile (`/tmp/nightcrawler-<project>.lock`) before any mutation — lockfile lives OUTSIDE repo to avoid contaminating git clean status
- If lockfile exists and PID is alive, refuse to start (another session is running)

### Network & External (project code layer)
- Project code NEVER makes HTTP requests outside of package managers (npm, forge, pip)
- Project code NEVER uses `curl`, `wget`, or fetches arbitrary URLs
- NEVER install packages from untrusted sources
- NEVER interact with deployed contracts or mainnet/testnet RPCs
- NEVER create accounts, authenticate with external services, or use OAuth

### Allowed Orchestrator Egress
The orchestrator layer (NOT project code) is allowed to contact:
- `api.anthropic.com` — Claude API calls
- `api.openai.com` — Codex API calls
- `api.twilio.com` — Telegram notifications (Twilio as watchdog fallback)
- `registry.npmjs.org` — npm package installs
- `github.com` — git clone/fetch only (never push)
- No other external endpoints

### Filesystem
- NEVER modify files outside the project repository and nightcrawler state repo
- NEVER delete files unless explicitly part of a task (e.g., removing dead code)
- NEVER modify the GLOBAL_PLAN.md — this is read-only
- NEVER modify nightcrawler/RULES.md or nightcrawler/SPEC.md
- Nightcrawler runs as a dedicated user (`nightcrawler`), not root
- Project paths: `/home/nightcrawler/projects/<project>`
- State path: `/home/nightcrawler/nightcrawler/`
- NEVER access `/root`, `~/.ssh`, `~/.config`, or other users' directories

### Execution
- NEVER run code with `sudo` or elevated privileges
- NEVER install global system packages
- NEVER start servers, daemons, or long-running processes outside of tests
- Project code NEVER executes network calls (API calls, webhooks, etc.)

### Subprocess Timeouts (enforced by orchestrator)
Every subprocess has a hard wall-clock timeout and a no-output timeout:

| Subprocess | Wall-clock max | No-output max | On timeout |
|-----------|---------------|---------------|------------|
| `forge build` | 5 min | 2 min | Kill, log, retry once |
| `forge test` | 10 min | 3 min | Kill, log, mark tests as failed |
| `npm install` | 5 min | 2 min | Kill, log as BLOCKER |
| `npm test` | 10 min | 3 min | Kill, log, mark tests as failed |
| Claude Code CLI (plan) | 10 min | 3 min | Kill, log, retry once |
| Claude Code CLI (impl) | 20 min | 5 min | Kill, log, retry once |
| Codex CLI (audit) | 5 min | 2 min | Kill, log, try API fallback |
| Any other subprocess | 5 min | 2 min | Kill, log as BLOCKER |

After 2 consecutive timeouts on the same step, declare LOCK and escalate.
Orchestrator MUST kill child process, release temp files, and clean up before moving on.

## Operational Rules (strong, override only via Telegram escalation)

### Task Discipline
- Only work on tasks from TASK_QUEUE.md, in order
- Never invent new tasks or features not in the queue
- Never re-prioritize the queue — order is set by Mateo
- If a task seems wrong or contradicts the Global Plan, log it and skip
- Never modify completed tasks or their commits
- Tasks use stable IDs (e.g., NC-001, NC-002), not positional numbers
- Dependencies reference task IDs, not positions
- NEVER start a task whose dependencies are not ALL in COMPLETED state
- Task eligibility is re-evaluated dynamically after each task completes — not precomputed at session start
- If a dependency is in a terminal failure state (BLOCKED, SKIPPED, or LOCKED), mark the dependent task DEP_BLOCKED
- Dependencies that are merely not yet completed (QUEUED, IN_PROGRESS) do NOT block — the dependent task stays QUEUED and is re-evaluated on the next loop iteration
- MANUAL tasks (marked [🚧]) are executed by Mateo, not Nightcrawler — skip automatically and move to next eligible task

### Loop Discipline
- Maximum 3 iterations per phase (plan or implementation) before declaring a lock
- A lock is declared when EITHER: 3 iterations are reached regardless of feedback theme, OR Jaccard keyword overlap >0.5 across last 3 rejections (whichever triggers first)
- Never implement without an approved mini-plan
- Never commit without an approved implementation review
- Each mini-plan must reference the specific task ID and acceptance criteria
- Each loop iteration prompt includes ONLY the latest plan/code + latest Codex feedback
- Previous iterations are summarized as single-line entries, never sent in full
- Lock detection uses keyword overlap (Jaccard similarity), never semantic model judgment

### Quality Standards
- Every implementation must include tests
- Tests must pass before submitting for review
- BASELINE CHECK: Before the FIRST task of a session, run full test suite and record the last-known-green commit hash. If tests already fail, escalate immediately — do not blame the first task
- PRE-FLIGHT: Before each subsequent task, run full test suite. If failing, compare against baseline. If new failures since baseline, escalate with the commit that introduced them
- POST-COMMIT: Run full build + test suite AFTER every commit. If it fails, auto-revert and re-enter implementation phase. If 2nd revert on same task, declare LOCK
- Commit messages must follow the format in SPEC.md
- Code must follow existing project patterns (read memory.md first)
- No TODOs in committed code — either implement fully or log as separate task

### Memory Management
- Orchestrator memory.md: max 100 active lines. Summarize entries older than 7 days
- Project memory.md: max 150 active lines. Same pruning strategy
- Never duplicate Global Plan content into memory — reference, don't copy
- Session logs (sessions/) are never auto-pruned — they're the audit trail

### Communication
- Send Telegram notifications only for events defined in ESCALATION.md
- Priority classes: URGENT (blocking escalations — always send immediately, bypass batching), NORMAL (task completions, warnings — batch in 15-min windows)
- URGENT messages bypass the rate limit. NORMAL messages cap at 5/hour
- Duplicate alerts for the same event coalesce (don't spam the same lock/failure)
- Escalation messages must include both positions and a clear question

### Budget
- Check budget BEFORE every model call. If projected cost of next call would exceed cap, stop
- Reserve $2.00 from session cap for mandatory end-of-session work (report generation, final notifications, potential revert). Never spend the reserve on tasks
- Effective task budget = session_cap - reserve - spent_so_far
- Alert at 80% of effective budget
- If a single task exceeds $5, pause and investigate
- Log every API call cost in session cost.jsonl (append-only JSONL, one object per line)
- Billing timezone: UTC. Session totals split by UTC day for daily cap enforcement

## Project Rules (configurable per project)

These are loaded from the project's CLAUDE.md and may vary. Examples for Clout:

- Use Foundry (forge) for Solidity development
- Follow OpenZeppelin patterns (ReentrancyGuard, Ownable, IERC20)
- USDT and USDC addresses are fixed (see GLOBAL_PLAN.md)
- All amounts use 6 decimals (stablecoin native)
- State machine transitions must be explicit and tested
- Every public function needs NatSpec documentation
