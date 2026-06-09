export const meta = {
  name: 'nightcrawler-loop',
  description: 'Run the Nightcrawler closed loop on one task: plan → implement → (codex-review ↔ fix)* → verify',
  whenToUse: 'Drive one task through the v2-lite Nightcrawler gate. Pass the task in args: a string, or {task, targetPath}.',
  phases: [
    { title: 'Classify',  detail: 'Cheap model rates complexity → routes the think-model (trivial→Sonnet, else Opus).' },
    { title: 'Plan',      detail: 'Think model reads relevant files, writes a short plan. No code.' },
    { title: 'Implement', detail: 'Think model makes the change in a dedicated git worktree.' },
    { title: 'Review',    detail: 'Thin runner execs codex_review.sh, echoes raw gate JSON (judgment is Codex).' },
    { title: 'Fix',       detail: 'Think model fixes blocking findings in the same worktree.' },
    { title: 'Verify',    detail: 'Thin runner execs verify.sh; pass→DONE, can\'t-run→inconclusive (not failed).' },
  ],
}

// ── Constants ──────────────────────────────────────────────────────────────
const ROUND_CAP = 3              // review↔fix rounds (skill default)
const INFRA_RETRIES = 2          // extra reviewer attempts when ran:false (total 3 tries)
const TOKEN_TARGET_K = 12        // soft per-agent token target; runtime agent caps are the real backstop

// Model routing. A cheap CLASSIFY pass (Phase 0) picks the THINK model by task tier, so a
// trivial change doesn't pay Opus latency/rate-limits while a hard one still gets the best
// model. The two runner agents (review/verify) stay cheap regardless — they only exec a
// script and echo JSON; the judgment lives in Codex (review) and verify.sh's exit code.
const TIER_MODEL = { trivial: 'sonnet', standard: 'opus', complex: 'opus' }
const MODEL_RUNNER = 'haiku'     // review-runner, verify-runner (no judgment to apply)
// The skill lives in ~/.claude/skills (installed), NOT committed to the repo, so
// the worktree checkout has no `.claude/skills/nightcrawler`. Always invoke the
// installed copy by absolute path; cwd is the worktree so the tools see the change.
const SKILL_SCRIPTS = '"$HOME/.claude/skills/nightcrawler/scripts"'
const REVIEW_CMD = `bash ${SKILL_SCRIPTS}/codex_review.sh`
const VERIFY_CMD = `bash ${SKILL_SCRIPTS}/verify.sh`
const PREP_CMD = `bash ${SKILL_SCRIPTS}/prep.sh`     // make a fresh worktree runnable before verify

// args may be a bare string or {task, targetPath}
const TASK = typeof args === 'string' ? args : (args && args.task) || ''
const TARGET = (args && typeof args === 'object' && args.targetPath) || ''
// Identity composability: a caller (e.g. the M1 feat-runner) can feat-scope this task's branch
// and worktree by passing branchPrefix (default 'nc/') and idSalt (default '' = standalone).
const BRANCH_PREFIX = (args && typeof args === 'object' && args.branchPrefix) || 'nc/'
const ID_SALT = (args && typeof args === 'object' && args.idSalt) || ''
if (!TASK) throw new Error('nightcrawler-loop: no task in args (pass a string or {task, targetPath})')

const softBudget = `Soft budget: aim to stay under ~${TOKEN_TARGET_K}k tokens. Be terse; do not over-explore.`
const targetLine = TARGET ? `Target path (start here): ${TARGET}` : 'No target path given — discover the relevant files yourself.'

// Deterministic worktree identity — computed here, never improvised by the agent.
// (Run-1 bug: the implement agent appended the repo path into git's commit-ish slot;
// we now hand it the exact command.)
// IMPORTANT: workflow scripts must be DETERMINISTIC so a resumed run replays identically —
// Math.random() and Date are banned (they break resume). The id is an FNV-1a hash of the
// task text: stable across a resume, distinct across different tasks. Re-running the SAME
// task collides on the branch/worktree on purpose — git fails loud; clean up or merge first.
function slugify(s) {
  return String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || 'task'
}
function fnv1a(str) {
  let h = 0x811c9dc5
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i)
    h = (h + ((h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24))) >>> 0
  }
  return h.toString(36)
}
// Salt makes the id feat-unique for a caller; empty salt preserves exact standalone hashing.
const RUN_ID = fnv1a(ID_SALT ? ID_SALT + '::' + TASK : TASK).slice(0, 6)
const SLUG = slugify(TASK)
const BRANCH = `${BRANCH_PREFIX}${SLUG}-${RUN_ID}`
const WT_REL = `../nc-wt-${SLUG}-${RUN_ID}`

// ── Schemas (only where the script needs structured fields) ──────────────────
const CLASSIFY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['tier', 'reason'],
  properties: {
    tier: { type: 'string', enum: ['trivial', 'standard', 'complex'] },
    reason: { type: 'string', description: 'one short sentence justifying the tier' },
  },
}
const PLAN_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['plan', 'relevant_files'],
  properties: {
    plan: { type: 'string', description: 'Short ordered plan. What to change and why. No code.' },
    relevant_files: { type: 'array', items: { type: 'string' }, description: 'Files the change will touch.' },
  },
}
const IMPL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['worktree_path', 'branch', 'summary'],
  properties: {
    worktree_path: { type: 'string', description: 'Absolute path of the git worktree where the change was made.' },
    branch: { type: 'string', description: 'Branch name created for the worktree.' },
    summary: { type: 'string', description: 'One-paragraph summary of what was changed.' },
    files_changed: { type: 'array', items: { type: 'string' } },
  },
}

// ── Helpers: the script — NOT an agent — parses the JSON the agents return ────
// Defensively extract the first balanced top-level JSON object from agent stdout.
function extractJsonObject(raw) {
  if (raw == null) return null
  let s = String(raw).trim()
  // strip ``` / ```json fences if the agent wrapped output despite instructions
  s = s.replace(/^```[a-zA-Z]*\s*/, '').replace(/\s*```$/, '').trim()
  const start = s.indexOf('{')
  if (start === -1) return null
  let depth = 0, inStr = false, esc = false
  for (let i = start; i < s.length; i++) {
    const c = s[i]
    if (inStr) {
      if (esc) esc = false
      else if (c === '\\') esc = true
      else if (c === '"') inStr = false
      continue
    }
    if (c === '"') inStr = true
    else if (c === '{') depth++
    else if (c === '}') { depth--; if (depth === 0) { try { return JSON.parse(s.slice(start, i + 1)) } catch (_) { return null } } }
  }
  return null
}

// Map any reviewer output to the gate contract. Anything we can't parse, or that
// lacks a boolean `ran`, is treated as an INFRA failure (ran:false) — same
// philosophy as adapter.py: never silently clean, never a rejection.
function asGate(raw) {
  const g = extractJsonObject(raw)
  if (!g || typeof g.ran !== 'boolean') {
    return { ran: false, error: 'reviewer output not parseable as gate JSON', clean: false, blocking: [], nonblocking: [] }
  }
  if (g.ran && g.clean !== true && !Array.isArray(g.blocking)) {
    return { ran: false, error: 'gate JSON missing blocking[] on non-clean verdict', clean: false, blocking: [], nonblocking: [] }
  }
  return g
}

function asVerify(raw) {
  const v = extractJsonObject(raw)
  if (!v || typeof v.pass !== 'boolean') {
    return { pass: false, failures: [{ stage: 'verify', exit: -1, log_tail: 'verify output not parseable as {pass, failures}' }], inconclusive: true }
  }
  return v
}

// ── Phase 0: CLASSIFY complexity → route the think-model ─────────────────────
phase('Classify')
const cls = await agent(
  `Classify the complexity of this ONE coding task. Reply with a tier:
- "trivial": a localized change of a few lines with obvious scope (a guard, a rename, a typo, a one-function fix).
- "standard": a normal change touching one area or file-set with clear intent.
- "complex": multi-file, ambiguous, architectural, or cross-cutting.

Task: ${TASK}`,
  { model: MODEL_RUNNER, phase: 'Classify', label: 'classify', schema: CLASSIFY_SCHEMA }
)
const tier = (cls && TIER_MODEL[cls.tier]) ? cls.tier : 'standard'
const thinkModel = TIER_MODEL[tier]
log(`Task classified "${tier}" → think model: ${thinkModel} (runners: ${MODEL_RUNNER}).`)

// ── Phase 1: PLAN (think model) ──────────────────────────────────────────────
phase('Plan')
const plan = await agent(
  `You are planning ONE Nightcrawler task. Do NOT write code in this phase.

Task: ${TASK}
${targetLine}

Read only the files needed to understand the change. Produce a short, ordered plan
(what to change, in which files, and why) plus the list of files the change will touch.
${softBudget}`,
  { model: thinkModel, phase: 'Plan', label: 'plan', schema: PLAN_SCHEMA }
)
if (!plan) return { status: 'aborted', stage: 'plan', task: TASK }
log(`Plan ready — ${plan.relevant_files.length} file(s) in scope.`)

// ── Phase 2: IMPLEMENT (Haiku — cheap) in a dedicated worktree ───────────────
phase('Implement')
const impl = await agent(
  `Implement ONE Nightcrawler task in an ISOLATED git worktree so review/verify can run against it cleanly.

Task: ${TASK}

Approved plan:
${plan.plan}

Files in scope: ${plan.relevant_files.join(', ') || '(discover from the plan)'}

Steps:
1. From the repo root, run EXACTLY this command and NOTHING ELSE. Do NOT append the repo
   path or any other argument — the new branch is created from the current HEAD:
     git worktree add -b ${BRANCH} ${WT_REL}
2. Get the worktree's ABSOLUTE path: run \`cd ${WT_REL} && pwd\` and use its output as worktree_path.
3. Make the change ONLY inside that worktree. Stay within the planned files unless the
   plan clearly requires touching an adjacent file.
4. Do NOT run type-check, tests, or codex review — later phases own that.
5. Return worktree_path (absolute), branch ("${BRANCH}"), and a one-paragraph summary.
${softBudget}`,
  { model: thinkModel, phase: 'Implement', label: 'implement', schema: IMPL_SCHEMA }
)
if (!impl) return { status: 'aborted', stage: 'implement', task: TASK, plan }
// SECURITY (audit F3): never trust the agent's returned path verbatim — it flows into
// cd/exec, and a hallucinated or injected value (/, $HOME, an attacker dir) would become a
// path-controlled exec primitive. Require it to end with the canonical worktree name we
// computed; otherwise refuse. Empty -> fall back to the deterministic relative path.
const WT_NAME = `nc-wt-${SLUG}-${RUN_ID}`
const claimed = (impl && typeof impl.worktree_path === 'string') ? impl.worktree_path : ''
if (claimed && !claimed.endsWith(WT_NAME)) {
  return { status: 'aborted', stage: 'implement', task: TASK, plan,
    note: `Implement agent returned an unexpected worktree path (${claimed}); expected one ending in "${WT_NAME}". Refusing to cd/exec into it.` }
}
const WT = claimed || WT_REL
log(`Implemented in worktree ${WT} (branch ${BRANCH}).`)

// ── Phase 3: REVIEW ↔ FIX loop (ROUND_CAP rounds) ────────────────────────────
// Reviewer is THIN: it runs the script and echoes raw stdout. No schema, no
// re-judging. The SCRIPT parses the JSON and branches.
function reviewerPrompt(attempt) {
  const backoff = attempt > 1
    ? `This is reviewer attempt ${attempt} after an infra failure. First run \`sleep ${attempt * 5}\` to back off, then proceed.\n`
    : ''
  return `You are a THIN reviewer. Your ONLY job is to run the Nightcrawler Codex review on
the worktree and return its stdout. Do NOT interpret, summarize, re-judge, or reformat.

${backoff}Run EXACTLY this one command (the worktree path is the argument — do NOT cd, do NOT add anything else):
  ${REVIEW_CMD} ${JSON.stringify(WT)}

Output the command's stdout VERBATIM as your entire reply — nothing before or after, no code
fences, no commentary. It is already JSON.`
}

let round = 0
let reviewPassed = false
let lastBlocking = []
let infraAbort = null

while (round < ROUND_CAP) {
  round++

  // 3a/3b: reviewer with bounded infra retries (ran:false ≠ rejection, ≠ clean)
  let gate = null
  for (let attempt = 1; attempt <= INFRA_RETRIES + 1; attempt++) {
    const raw = await agent(reviewerPrompt(attempt), {
      model: MODEL_RUNNER, phase: 'Review', label: `review:r${round}.a${attempt}`,
    })
    gate = asGate(raw)
    if (gate.ran) break
    log(`Round ${round}: reviewer infra failure (${gate.error}) — attempt ${attempt}/${INFRA_RETRIES + 1}.`)
  }

  if (!gate.ran) {
    // Exhausted infra retries. NOT a rejection, NOT clean — stop and surface infra.
    infraAbort = gate.error
    break
  }

  // 3c: clean → done with review
  if (gate.clean === true) {
    reviewPassed = true
    log(`Round ${round}: review CLEAN (no priority≤2 findings).`)
    break
  }

  // 3d: blocking findings → fix in the SAME worktree, then loop
  lastBlocking = Array.isArray(gate.blocking) ? gate.blocking : []
  log(`Round ${round}: ${lastBlocking.length} blocking finding(s) — dispatching fix.`)
  await agent(
    `Fix the BLOCKING review findings below, in the EXISTING worktree. Do not refactor
beyond what each finding requires. Do not touch P3 nits.

Worktree: ${WT}
  cd ${JSON.stringify(WT)}

Blocking findings (Codex, priority ≤ 2):
${JSON.stringify(lastBlocking, null, 2)}

Apply the minimal correct fix for each. Do not run review or verify — the loop owns that.
${softBudget}`,
    { model: thinkModel, phase: 'Fix', label: `fix:r${round}` }
  )
}

if (infraAbort) {
  return {
    status: 'infra_error', task: TASK, worktree: WT, branch: BRANCH,
    rounds: round, error: infraAbort,
    note: 'Codex reviewer never produced a usable verdict. Not a rejection and not clean — needs a human / infra check.',
  }
}

if (!reviewPassed) {
  // Hit ROUND_CAP with priority≤2 findings still present. Stop; do NOT verify.
  return {
    status: 'review_unresolved', task: TASK, worktree: WT, branch: BRANCH,
    rounds: round, blocking: lastBlocking,
    note: `Reached ROUND_CAP=${ROUND_CAP} with blocking findings still present. Surfaced for human review.`,
  }
}

// ── Phase 3.5: PREP — make the fresh worktree runnable (Node deps) before verify ─
// A fresh git worktree has no node_modules; without this, verify can't RUN there (127 →
// inconclusive). Node-only; non-node stacks no-op. Runs after review passes (review/fix
// don't need deps), so we only install when we're about to verify. Install failure →
// verify_inconclusive (env not ready, NOT code-red).
phase('Prep')
const prepRaw = await agent(
  `THIN prep runner. Run EXACTLY this one command and output its stdout VERBATIM as your entire reply
(JSON {prepped, ran, ...}); no fences, no commentary:
  ${PREP_CMD} ${JSON.stringify(WT)}`,
  { model: MODEL_RUNNER, phase: 'Prep', label: 'prep' }
)
const prepResult = extractJsonObject(prepRaw)
if (!prepResult || prepResult.prepped !== true) {
  return {
    status: 'verify_inconclusive', task: TASK, worktree: WT, branch: BRANCH, rounds: round,
    failures: [{ stage: 'prep', kind: 'missing_tool',
      log_tail: (prepResult && (prepResult.log_tail || prepResult.error)) || 'worktree dependency install failed or unparseable' }],
    note: 'Could not prepare the worktree to run (dependency install failed) — env not ready, NOT a code failure. Check the package manager / lockfile and re-run.',
  }
}
log(prepResult.ran ? `Prep: installed worktree deps (${prepResult.ran.join(' ')}).` : 'Prep: no dep install needed.')

// ── Phase 4: VERIFY (deterministic ground truth — final, non-negotiable gate) ─
phase('Verify')
const verifyRaw = await agent(
  `Run the Nightcrawler verification on the worktree and return its stdout JSON verbatim.

Run EXACTLY this one command (the worktree path is the argument — do NOT cd, do NOT add anything else):
  ${VERIFY_CMD} ${JSON.stringify(WT)}

Output the command's stdout VERBATIM as your entire reply (it is JSON {pass, failures}).
No fences, no commentary.`,
  { model: MODEL_RUNNER, phase: 'Verify', label: 'verify' }
)
const verify = asVerify(verifyRaw)

// A clean review does NOT override a failing verify.
if (verify.pass === true) {
  return {
    status: 'done', task: TASK, worktree: WT, branch: BRANCH,
    rounds: round, summary: impl.summary,
    note: 'Review clean and verify passed. Worktree left in place for human merge/inspection.',
  }
}

// Infra-vs-findings for verify: if the checks could NOT run (toolchain/deps missing, or no
// verifier detected) that is NOT a code failure — surface it distinctly so a missing env never
// masquerades as broken code (the run-1 false negative: turbo not found in a fresh worktree).
if (verify.inconclusive) {
  return {
    status: 'verify_inconclusive', task: TASK, worktree: WT, branch: BRANCH,
    rounds: round, failures: verify.failures || [],
    note: 'Verification could not RUN (toolchain/deps missing in the worktree, or no verifier detected) — NOT a code failure. Fix the environment (install deps / correct node; see env_check) and re-run.',
  }
}

return {
  status: 'verify_failed', task: TASK, worktree: WT, branch: BRANCH,
  rounds: round, failures: verify.failures || [],
  note: 'Review was clean but deterministic verify ran and did not pass. Code is NOT done.',
}
