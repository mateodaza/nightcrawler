# PLAN — Phase C (Queue Reconciliation) + Phase B (Audit Contract) + Phase F (Grounded Companion)

**Status:** draft · 2026-04-19
**Predecessor:** PLAN-stabilization.md (Phase A — streaming + envelopes, shipped)
**Successors (pre-existing, unchanged):** PLAN-context-awareness.md (Phase D), PLAN-v3.md Tier 1 (Phase E)

---

## Shipped log

Last updated 2026-04-19. Pull `git log --oneline` for the authoritative view.

| Phase | What | Commit |
|---|---|---|
| C0 | Deterministic shipped-task guard (reconcile + post-pick) | earlier |
| B0 | Structured auditor contract v2 (verdict / blocking_issues / advisories / irrelevant / confidence / complexity_tier) | earlier |
| F1 | Relevance pack builder + default-on flip | `75003fc` |
| F1 ops | `nc_pack_health.py` one-screen canary monitor | `c25175c` |
| F2 | Structured confidence guidance + low-conf coerce flag + journal enrichment | `def1353` |
| F1 fix | Ranker: demote bookkeeping in impl_review + per-file cap 2500 + truncate-to-fit | `cf1d86f` |

**Phase BCF MVP gate (per ship order below):** C0 + F1 + F5. F5 is the last remaining
MVP piece — F2/F3 were taken out of order because live probe evidence surfaced F2's
signal as the higher-priority unblocker. F3, F4, F6, B4 are all pending, with F3/F4
explicitly held for next-live-run evidence before implementation.

---

## Guiding principle

> **Confidence should come from local evidence and prior project knowledge, not from global reviewer personality.**

Everything in this plan is in service of that sentence. The NC-SMOKE run on camello (2026-04-19) surfaced a pipeline that was simultaneously:
- picking stale tasks (re-implementing shipped work — a correctness bug),
- rejecting on bureaucratic grounds ("TASK_QUEUE.md was modified" — free-associating from the literal spec with no project grounding),
- inflating plans under audit pressure (1074 → 6981 chars for a one-file task),
- running under the wrong project persona (`call_codex.py:246` hardcoded "Solidity/Foundry" while reviewing TS/Next.js).

The answer isn't "make the reviewer more assertive." It's: **ground the reviewer on the parts that matter, keep it quiet on irrelevant surface area, and have it be explicit about why it's confident**. A companion layer, not more pressure on the auditor.

---

## TL;DR

Three phases, tackled in this order:

- **Phase C — Queue Reconciliation.** Correctness fix. Today the picker is literally told (`nightcrawler.sh:674`) to pick `[ ]` tasks even when git shows the work is already committed, on a promise of downstream verification that doesn't exist. On unlimited budget this re-implements shipped tickets. Must be fixed first.
- **Phase B — Structured Audit Contract.** Minimal plumbing Phase F needs: replace `{verdict, feedback}` with a structured return so F2/F3 have somewhere to put structured confidence and bucketed issues. Plus one safety rail (planner inflation guard) that doesn't belong in F.
- **Phase F — Grounded Companion.** The through-line. Six items turn the reviewer from a stateless, stance-driven auditor into a grounded companion with a relevance pack, explicit confidence, a third "irrelevant" bucket, project memory, shipped-task awareness, and task-type modes.

**If we ship only three: C0 + F1 + F5.** C0 closes the correctness hole at the scheduler. F1 (relevance pack) is the single biggest lever for "stop free-associating." F5 (companion-side shipped-task awareness) is the second line of defense on top of C0 — an LLM check that catches what regex reconcile misses. Everything else refines this core.

Overlap note: the earlier draft of this plan had Phase B items B1/B2/B3 that, on reflection, were really F items in disguise. They're folded into F below. B shrinks to B0 (contract) + B4 (planner guardrail).

---

## Phase C — Queue Reconciliation (correctness)

### C0 — Deterministic shipped-task guard [**SHIP-3**]

**Problem.** `nightcrawler.sh:674` instructs the Sonnet picker: "If a task is marked `[ ]` but the git log shows it was already implemented… Still pick it — the orchestrator will verify and skip if truly done." There is no such verify step. The NC-SMOKE session proved it: after NC-SMOKE shipped, the picker selected NC-386, which had already been committed and pushed in an earlier session but was still `[ ]` in TASK_QUEUE.md. Caught by a tight `--budget 5`; on unlimited budget it would have re-planned and re-implemented the ticket.

**Two checks, defense-in-depth:**

**Pre-pick reconcile** — before `pick_next_task`:
- Range: `$(git merge-base main nightcrawler/dev)..nightcrawler/dev` (explicit merge-base is safer than `nightcrawler/dev ^main` around odd histories — force-pushes, interrupted merges, old branches where `main` has diverged).
- `git log <range> --pretty='%H %s %(trailers:key=Nightcrawler-Task,valueonly=true)'`
- Extract task IDs via trailer (see C1.5) first, regex fallback on `feat(NC-XXX)` second.
- **Revert / reopen escape hatch.** Before flipping `[ ]` → `[x]`, check two conditions that override reconcile:
  - *Revert detected:* a later commit in the same range whose subject matches `Revert "[nightcrawler] feat(NC-XXX)` or contains the shipped commit's SHA in a `Revert of <sha>` trailer. If found, skip the flip and log `reconcile_skipped_due_to_revert`.
  - *Queue reopened:* TASK_QUEUE.md contains a `@reopened` sentinel on the task line (e.g. `#### NC-386 [ ] @reopened: <reason>`), or the task's line has been edited since the shipped commit's date (detectable via `git blame TASK_QUEUE.md | grep NC-XXX`). If found, skip the flip and log `reconcile_skipped_task_reopened`.
- For each `[ ]` or `[~]` task whose ID is found AND passes the escape-hatch checks, flip to `[x]`.
- Commit the update as `[nightcrawler] chore: reconcile queue — mark N tasks shipped`.
- Emit per-task and summary journal events (see C2.5).

**Post-pick guard** — after `pick_next_task` returns, before `plan_task`:
- Grep the same `merge-base..nightcrawler/dev` range for the chosen task ID.
- Apply the same revert/reopen escape hatch. If match survives, mark `[x]`, emit `queue_drift_caught` event, re-enter pick loop (up to 3x, then exit cleanly).
- If match fails escape hatch (task was reverted or reopened), proceed to plan normally — the task is genuinely open again.
- **No LLM tokens spent on the already-shipped task unless escape hatch fires.**

Why both layers? Regex+trailer reconcile will miss edge cases (squash merges, rebase rewrites, non-standard subjects). The post-pick guard is the hard stop so no single miss becomes "re-implemented." Why the escape hatch? Deterministic guards need one explicit way out — otherwise a reverted task stays `[x]` forever despite genuinely needing re-work.

**Files:** `scripts/nightcrawler.sh` — new `reconcile_queue()` and `verify_task_not_shipped()` functions; call sites before `pick_next_task` and after it.

**Acceptance:**
- Dry-run on camello flips NC-386/387/388 (whichever are actually shipped but `[ ]`) and leaves open tasks alone.
- Adversarial test: inject a `[ ]` for a task whose commit exists; session picks it, guard catches it, flips to `[x]`, picks next, no planning occurs.
- No false positives on ID substrings (`NC-38` doesn't match `NC-386`).

**Rollback:** `NC_RECONCILE_QUEUE=1` flag, default off until one clean overnight.

---

### C1.5 — Structured commit ↔ task mapping

**Problem.** Regex on `feat(NC-XXX)` rots: squash-merges, human-authored commits, multi-task commits. Need a structured identifier.

**Change.**
- Every orchestrator commit gets a `Nightcrawler-Task: <ID>` trailer (comma-separated for multi-task).
- Reconcile parser reads trailer first, falls back to regex with a `reconcile: task NC-XXX matched via regex (no trailer)` log line.
- Convention documented in `RULES.md`.

**Files:** `scripts/nightcrawler.sh` (commit message builder), `RULES.md`.

**Acceptance:** new commits have the trailer; reconcile prefers trailer; regex fallbacks are logged.

**Rollback:** trailer is additive, zero cost if unread.

---

### C2 — `reconcile_queue` as an implementation primitive (not a first-class command)

**Status (2026-04-19):** demoted from user-facing standalone command. `reconcile_queue()` is an internal primitive only. The one user-facing sync command is `nightcrawler update` (PLAN-v3.md Tier 1.2), which absorbs the reconcile step.

**Scope retained.**
- `reconcile_queue()` must be callable outside the session loop so `nightcrawler update` can invoke it, and so recovery scripts can call it during crash cleanup. Extract to `scripts/lib/` if that's the cleanest shape, but do not ship a `scripts/reconcile.sh` wrapper, a `/reconcile` Telegram command, or any other first-class surface.
- Behavior is identical to the C1 in-session call: no lock, merge-base range, trailer+regex, propose+commit TASK_QUEUE update on `nightcrawler/dev`, honor `--dry-run` when invoked by `update`.

**Files:** extract `reconcile_queue` to a reusable location consumed by `scripts/nightcrawler.sh` (C1) and `nightcrawler update` (E1.2).

**Acceptance:** `nightcrawler update --dry-run` prints the same diff that an in-session reconcile would commit. No separate `reconcile.sh` exists on disk.

**Rollback:** not applicable — primitive, not a surface. If `update` regresses, flip its flag.

---

### C2.5 — Queue-drift journal events

**Problem.** When reconcile flips `[ ]` → `[x]`, or the post-pick guard catches a stale task, we need an audit trail. Otherwise six months from now "why did Nightcrawler skip NC-412?" has no answer.

**Change.** First-class journal events:
- `{"event":"queue_reconciled","task_id":"NC-386","source":"trailer|regex","commit":"<sha>","ts":"..."}`
- `{"event":"queue_drift_caught","task_id":"NC-386","commit":"<sha>","ts":"..."}`
- `{"event":"queue_reconcile_summary","flipped":3,"unchanged":12,"ts":"..."}`

**Files:** wherever `journal.jsonl` is written today.

**Acceptance:** `jq 'select(.event=="queue_reconciled")' journal.jsonl` returns one row per flip. Out-of-band runs write to a shared `reconcile.jsonl`.

**Rollback:** additive.

---

## Phase B — Structured Audit Contract (plumbing)

### B0 — Structured auditor contract

**Problem.** `call_codex.py:246` returns `{verdict, feedback}` — a single binary plus free-form text. Line 270–271 says "No vague concerns" but the contract still forces blocking issues, advisories, and musings into one string. F2 (structured confidence) and F3 (bucketed issues) can't exist without first changing this contract.

Separately: `call_codex.py:246` opens with `"You are an independent code auditor for a Solidity/Foundry project."` — hardcoded for Clout, wrong on camello. Must become project-driven.

**Change. New return shape:**

```json
{
  "verdict": "APPROVED" | "REJECTED",
  "blocking_issues": [
    {
      "reference": "AC line or spec pointer",
      "current_state": "what plan/impl does today",
      "required_change": "concrete diff-level or file-level change",
      "severity": "high|medium"
    }
  ],
  "advisories": [{"note": "...", "rationale": "..."}],
  "irrelevant": [{"note": "...", "why_skipped": "..."}],
  "complexity_tier": "TRIVIAL" | "STANDARD" | "RISKY",
  "confidence": "high" | "medium" | "low",
  "why_confident": "...",
  "what_would_change_my_mind": "...",
  "schema_version": 2
}
```

*Parser rules:*
- `APPROVED` → ship, advisories logged.
- `REJECTED` with empty `blocking_issues` → coerced to `APPROVED` with advisories, logged as `audit_contract_violation`. Catches vague rejections.
- `irrelevant[]` is new. Forces enumeration of what the reviewer chose not to flag. This is calibration data for future tuning — patterns that show up repeatedly in `irrelevant` become candidates for F4 (area memory).
- `confidence`, `why_confident`, `what_would_change_my_mind` feed F2.
- `complexity_tier` ownership: **orchestrator derives first, auditor may suggest override.** The orchestrator computes the initial tier deterministically from the task spec (see F6 heuristic). That tier is injected into the audit prompt and drives loop control. The auditor returns its own `complexity_tier` as an observation — if it disagrees with the orchestrator's tier, the mismatch is logged as `tier_mismatch` but the orchestrator's tier still owns loop iteration caps. This keeps loop control deterministic (auditor can't talk its way into more iterations) while preserving the override signal as calibration data for tuning the heuristic over time.

*Prompt changes:*
- Remove the Solidity/Foundry persona. Load `config/projects/<project>/audit-persona.md` with a generic fallback.
- Keep the "fast iteration, not polish" philosophy line from `call_codex.py:260-261` — it's well-tuned.
- Explicit instruction: "If you cannot articulate a concrete `required_change` for a blocking issue, it belongs in advisories, not blocking_issues."

**Files:** `scripts/call_codex.py` (both `audit_plan` and `review_impl`); `scripts/nightcrawler.sh` (new contract consumers); `config/projects/camello/audit-persona.md` (new); `config/projects/clout/audit-persona.md` (new — move current Solidity prompt here).

**Acceptance:**
- Both audits return the new JSON shape.
- Camello audits no longer reference Solidity patterns.
- Unit test: mocked vague rejection coerces to APPROVED with advisory, logs contract violation.

**Rollback:** `schema_version: 2` on new shape; keep v1 parser as fallback. Bump contract back without reverting code.

---

### B4 — Plan-inflation guard

**Problem.** NC-SMOKE plan grew 1074 → 4564 → 6981 chars across three revisions for a task that needed one file write. The planner inflates under audit pressure. This is a planner guardrail, not a reviewer change — stays in B, not F.

**Change.** After `revise_plan`:
- If revised plan > 2× previous AND task AC/spec unchanged, classify as `plan_inflation`.
- **Don't silently reuse the old plan.** Instead:
  - Keep previous plan as "best-known."
  - Attach auditor advisory: `plan_inflation_detected` with both char counts.
  - Continue with prior approved/best-known plan.
  - Journal event `plan_inflation_event` with before/after sizes.

Makes behavior explainable. Logs show what happened, operators can tell "stopped escalating" vs "actually converged."

**Files:** `scripts/nightcrawler.sh` (`plan_task` / `revise_plan`); journal event.

**Acceptance:** synthesized trivial task with forced auditor rejections → planner inflates → guard catches, logs, uses prior plan, impl proceeds.

**Rollback:** `NC_PLAN_INFLATION_GUARD=1`, default off until tested.

---

## Phase F — Grounded Companion

The heart of the plan. Six items, each addressing a specific failure mode we saw on NC-SMOKE or know to be latent.

### F1 — Relevance pack builder [**SHIP-3**]

**Problem.** The current auditor is stateless and receives only the task text, the plan, and a generic project context (`_read_project_context()` in `call_codex.py` — currently Solidity-only globs). It free-associates from there. Of the three NC-SMOKE plan-audit rejections, all three cited concerns that would have been resolved by pointing the reviewer at a concrete file (a branch-check utility, the orchestrator's own `commit_task` logic, the allowlist of orchestrator-owned files). The reviewer was ungrounded.

**Change.** Before every plan audit and impl review, build a **relevance pack** — a small, deterministic context bundle:

```
RELEVANCE PACK for NC-XXX (plan audit)
═══════════════════════════════════════

## Task
<full task spec text>

## Likely touched files
<files listed in task ## Files section + files grep'd by task keywords from AC>

## Recent commits in this area (last 10)
<git log -10 --follow on the likely-touched files>

## Prior reviewer findings in this area (last 5 sessions)
<grep journal.jsonl for audit events on tasks that touched the same files>

## Spec/docs referenced by the task
<files named in the task spec: RULES.md, SPEC.md, named PLAN-*.md>

## Area memory
<contents of config/projects/<project>/audit-patterns.md — see F4>
```

Then tell the model, up front:

> Only comment on things supported by this pack — either by direct reference to a file/commit/prior-finding, or by a direct contradiction you can point to in the code. If you cannot ground a concern in the pack or in code, it belongs in `advisories[]` at most.

**Files:** `scripts/lib/relevance_pack.py` (new — builds the pack); call sites in `call_codex.py` that assemble the final audit prompt.

**Selection provenance — log every decision.** The pack is only as good as its selection. When the pack is wrong, debugging it is miserable unless we can see *why* each file was included. Emit a sidecar `relevance_pack.meta.json` alongside every pack, structured:

```json
{
  "task_id": "NC-XXX",
  "phase": "plan_audit",
  "entries": [
    {"file": "scripts/nightcrawler.sh", "reason": "matched task keyword 'picker' in AC", "bytes": 4120, "rank": 1},
    {"file": "scripts/call_codex.py", "reason": "cited by file:line reference in task spec", "bytes": 3800, "rank": 2},
    {"file": "PLAN-stabilization.md", "reason": "named in task ## Spec/docs section", "bytes": 2100, "rank": 3},
    {"file": "config/projects/camello/audit-patterns.md", "reason": "always-included area memory", "bytes": 890, "rank": 0}
  ],
  "excluded_candidates": [
    {"file": "scripts/lib/stream-accumulator.py", "reason": "keyword match but size >20KB, summarized instead"}
  ],
  "total_bytes": 10910,
  "ts": "..."
}
```

This is cheap (the selector already knows why it picked each file — just write it out) and turns "the pack is wrong" into a concrete diff-able artifact.

**Acceptance:**
- Every audit prompt on the wire contains the pack (check via stderr logging of the prompt for one session).
- Every pack has a sibling `.meta.json` with the selection rationale for every entry.
- Replay the NC-SMOKE plan audit against the new prompt with pack — either fewer rejections, or rejections that cite specific pack entries rather than freeform concerns.
- Pack size stays bounded (~5–15 KB typical) — large file lists are summarized, not dumped whole; summarization decisions appear in `excluded_candidates`.

**Rollback:** `NC_RELEVANCE_PACK=1`, default on after first validation. Disabling reverts to current prompt behavior.

---

### F2 — Structured confidence output

**Problem.** Today "APPROVED / REJECTED" is the only signal. An auditor saying "low-confidence approve because I couldn't find the spec for branch-state behavior" is strictly more useful than a high-confidence approve that's actually a guess.

**Change.** Depends on B0 contract. Require the reviewer to fill:
- `confidence: high | medium | low`
- `why_confident`: brief, concrete — cites a file/commit/pack-entry.
- `what_would_change_my_mind`: what evidence would flip the confidence level.

Examples:
- *high:* "task maps cleanly to existing pattern in `commit_task()` in `nightcrawler.sh:2140`, same shape as NC-385 impl."
- *low:* "AC mentions branch-state behavior but no source of truth for expected behavior is in the pack; a spec file would raise this to medium."

Downstream uses:
- Any `REJECTED` with `confidence: low` and no pack-grounded blocking issue → auto-downgrade to advisory, session proceeds.
- Journal captures `confidence` on every audit for later correlation with actual task outcomes.

**Files:** `scripts/call_codex.py` (prompt + validator); journal events.

**Acceptance:**
- Audit outputs include all three fields.
- Low-confidence unfounded rejections auto-downgrade (with contract-violation log).

**Rollback:** lives inside B0 contract; disable by reverting contract.

---

### F3 — Blocking / advisory / irrelevant split

**Problem.** `APPROVED/REJECTED` funnels everything through one gate. A smart companion should say: *must fix* vs *good idea* vs *I looked and chose to skip*.

**Change.** Three buckets on every audit (from B0 contract):

- `blocking_issues[]` — must fix before proceeding. Max 3. Each must have `required_change` and `reference`. Each must map to an AC line, spec line, or a direct code contradiction. No `required_change` → forced into advisories.
- `advisories[]` — good ideas, not worth a loop. Logged to journal, attached to commit message, never blocks ship.
- `irrelevant[]` — **the innovation.** Forces the reviewer to enumerate things it considered and chose not to flag, with `why_skipped`. Examples: "`TASK_QUEUE.md` modification — orchestrator-owned, per area memory." Or: "test verbosity — explicitly descoped per project philosophy." Over time, patterns here become calibration data for F4's area memory.

**Files:** `scripts/call_codex.py` (prompt); parser to validate each bucket's constraints.

**Acceptance:**
- Audit outputs populate all three buckets.
- `irrelevant[]` is logged to journal — analysis over time surfaces patterns that should be promoted into area memory.

**Rollback:** lives inside B0.

---

### F4 — Area memory (project-local patterns) [subsumes prior B1]

**Problem.** Every audit starts cold. The reviewer doesn't know that TASK_QUEUE.md is orchestrator-owned, that PROGRESS.md is append-only bookkeeping, that camello uses pnpm and Drizzle, that Clout uses Foundry, that trivial tasks shouldn't invent architecture, etc. Every session relearns these from first principles — or fails to.

**Change.** Per-project `config/projects/<project>/audit-patterns.md`, loaded into every audit prompt (as part of F1's relevance pack). Starter content:

```markdown
# Audit patterns — camello

## Orchestrator-owned files (never count toward scope violations)
- TASK_QUEUE.md           — Nightcrawler updates status markers every task
- PROGRESS.md             — append-only session log
- .nightcrawler/**        — session artifacts, locks, envelopes
- Any file whose first 10 lines contain `@nightcrawler-managed`

When evaluating "only X modified" constraints, treat these as invisible.
If a spec intends to restrict them, it will name them explicitly.

## Project conventions
- Stack: Next.js 15, Hono/tRPC, Drizzle, pnpm monorepo
- Branch: session work pushes to `nightcrawler/dev`, base is `main`
- Commit convention: `[nightcrawler] feat(NC-XXX): <subject>` with `Nightcrawler-Task:` trailer

## Known priors
- For trivial tasks: do not invent architecture; cite existing patterns.
- If code already exists for the task: reconcile queue before planning.
- Planner may flag [AMBIGUOUS:] or [INTERPRETED:] tags — evaluate reasonableness, don't reject for ambiguity itself.
```

This extends the prior B1 (orch-owned allowlist) into a broader project-memory file. B1 was a narrow slice; F4 is the whole space.

Apply to **both** plan audit and impl review (original B1 correctness).

**Files:**
- `config/projects/camello/audit-patterns.md` (new)
- `config/projects/clout/audit-patterns.md` (new)
- `config/projects/_template/audit-patterns.md` (starter template for new projects)
- `scripts/lib/relevance_pack.py` includes `audit-patterns.md` in every pack.

**Acceptance:**
- Replay NC-SMOKE impl audit with F4 active — TASK_QUEUE.md is no longer flagged as a scope violation.
- Adversarial test: spec says "only modify src/foo.ts" and impl modifies src/bar.ts — audit still blocks (patterns are additive, not override).

**Rollback:** remove the `audit-patterns.md` include from the pack builder.

---

### F5 — Shipped-task awareness (companion-side) [**SHIP-3**]

**Problem.** C0 is the scheduler-side hard guard: git-log regex + trailer match, deterministic. F5 is the companion-side soft check: *reason* about whether the task is already shipped before planning, catching cases regex misses (renames, refactors that span commits, accidental multi-task commits).

**Change.** A new pre-plan companion check. Before `plan_task` runs its normal Sonnet planning call, a small Claude prompt with the relevance pack asks:

```
Given the task spec and this relevance pack, evaluate one question only:

IS THIS TASK ALREADY IMPLEMENTED?

Output one of:
- SHIPPED: cite commit SHA(s) that satisfy the AC.
- PARTIAL: cite what exists + what's missing.
- NOT_SHIPPED: proceed to plan.
- UNCERTAIN: pack is insufficient to tell.

Ground your answer in the relevance pack. Do not plan; do not propose changes.
```

**F5 is advisory-only for state changes.** Deterministic state changes (`[ ]` ↔ `[x]`) belong to C0. F5 observes and signals; it never writes to TASK_QUEUE.md.

Routing:
- `SHIPPED` → **do not flip the task marker**. Instead: abort the current iteration with a `companion_shipped_signal` journal event citing the commit SHAs, then trigger a manual-reconcile path — either (a) run the C0 reconcile pass again in case it missed the commit on a second look, or (b) emit a Telegram notification `"F5 flagged NC-XXX as shipped — run /reconcile to confirm"` and pick the next task. Operator (or `/reconcile`) makes the actual state decision.
- `PARTIAL` → proceed to plan, but inject the "what exists" finding into the planner prompt so the plan is incremental, not duplicative. No state mutation.
- `NOT_SHIPPED` → proceed normally.
- `UNCERTAIN` → proceed to plan, log `companion_uncertain` event for later review.

C0 (scheduler) + F5 (companion) together are two layers of defense, with distinct responsibilities:
- **C0 owns state.** Deterministic rules, runs on every pick, flips markers, handles revert/reopen escape hatch. Every state change has a regex-or-trailer pedigree that can be audited.
- **F5 owns signal.** LLM reasoning about repo state, catches cases where code exists but commit history is messy (renames, cross-task landings). Never flips markers — it surfaces the case to C0 (via a re-reconcile trigger) or to the operator.

This split preserves the core property you want: **deterministic changes stay deterministic**. F5 can be wrong without corrupting the queue.

**Files:** `scripts/nightcrawler.sh` (new `companion_shipped_check` before plan), new prompt in `scripts/lib/companion-prompts/`.

**Acceptance:**
- Synthesize a task whose AC is satisfied by existing code but with no matching commit subject (e.g., function exists, was landed under a different task ID) — F5 catches it, C0 doesn't.
- On NC-SMOKE-style trivial tasks with zero existing code, F5 returns NOT_SHIPPED in one Sonnet call (<15s), no false positives.

**Rollback:** `NC_COMPANION_CHECK=1`, default off until validated.

---

### F6 — Task-type modes (companion stance) [subsumes prior B2]

**Problem.** The prior B2 (complexity tier) only changed loop iteration counts. What Mateo correctly surfaced: different task types need different **stances**, not just different iteration counts.

**Change.** Three modes, dispatched by `complexity_tier`:

| Tier | Companion stance | Plan audit | Impl review | Rejection bar |
|---|---|---|---|---|
| **TRIVIAL** | Companion mode: advisory-heavy, one-pass, *do not invent architecture* | 1 pass only, advisories allowed, no replan | 1 pass only, advisories allowed | blocking issues only, with concrete `required_change` |
| **STANDARD** | Normal reviewer | current loop | current loop | current bar |
| **RISKY** | Strict auditor | current loop | current loop | stricter — medium advisories promote to blocking |

The word "companion mode" for TRIVIAL matters. It's not just "fewer iterations" — it's a different prompt stance. Injected into the audit system prompt as:

```
STANCE: companion mode.
This is a TRIVIAL task. Your job is to sanity-check, not to review.
Do not propose architectural changes. Do not relitigate conventions.
Blocking issues: only concrete spec violations with named references.
Advisory notes: welcome, but never gate the ship.
```

Tier derivation (cheap pre-LLM heuristic in bash, same as prior B2):
- ≤2 AC bullets + ≤1 file listed + est. diff <50 lines → TRIVIAL
- Keyword match: `migration`, `schema`, `auth`, `crypto`, `delete`, `drop` → RISKY
- Default → STANDARD

Auditor also returns `complexity_tier` in B0 contract; disagreements log `tier_mismatch`.

**Files:** `scripts/nightcrawler.sh` (`derive_complexity_tier()`), audit prompt assembly adds stance block based on tier.

**Acceptance:**
- Replay NC-SMOKE with F1+F4+F6 → TRIVIAL, companion mode, plan approved iter 1, impl approved iter 1, wall time <5 min.
- Synthesize a schema-migration task → RISKY, strict bar, any medium advisory promoted to blocking.
- Journal has `task_tier` + `stance_applied` events per task.

**Rollback:** `NC_COMPLEXITY_TIER=1`, off → everyone gets STANDARD.

---

## Ship order & testing strategy

**Order:**

1. **C0** — correctness, must go first. One throwaway test on camello: reset a known-shipped task to `[ ]`, verify pre-pick reconcile + post-pick guard both catch it.
2. **C1.5** — trailer convention (tiny, ships with C0 naturally).
3. **B0** — structured contract (plumbing F needs).
4. **F1** — relevance pack (biggest grounding lever, doesn't depend on B0 but benefits from it).
5. **F4** — area memory (lives inside F1's pack; write `audit-patterns.md` for camello and clout).
6. **F5** — companion shipped-task check (second line of defense on top of C0).
7. **F2 + F3** — confidence output + three buckets (need B0 contract).
8. **F6** — task-type modes.
9. **B4** — planner inflation guard.
10. **C2** — extract `reconcile_queue` as a reusable primitive for `nightcrawler update` (E1.2). No standalone command.
11. **C2.5** — journal events for reconcile + drift-caught.

**Validation pattern between phases.** Each phase ships with one throwaway task on camello to prove the specific failure mode is closed:
- Post-C0: adversarial stale `[ ]` → correctly skipped, flipped to `[x]`.
- Post-F1+F4: replay NC-SMOKE plan audit → no freeform rejection, grounded concerns only.
- Post-F5: fabricated "already-shipped under different task ID" scenario → F5 catches, C0 doesn't.
- Post-F6: side-by-side TRIVIAL task + RISKY task → stance differentiation visible in audit output.

**Phase exit criteria.** C0 + F1 + F5 shipped → Phase BCF "MVP complete." Everything else is enhancement; each item ships independently without blocking Phase D.

**Flags and defaults:**
- `NC_RECONCILE_QUEUE` — off until one clean overnight, then on.
- `NC_RELEVANCE_PACK` — off until F1 validated, then on (high-impact, low-risk).
- `NC_COMPANION_CHECK` — off until F5 validated.
- `NC_COMPLEXITY_TIER` — off until F6 validated.
- `NC_PLAN_INFLATION_GUARD` — off until B4 validated.
- B0/F2/F3/F4 aren't flagged — they're prompt + contract rewrites, rollback is `git revert` or schema_version bump.

---

## What follows Phase BCF

- **Phase D — PLAN-context-awareness.md** (9 phases, zero shipped). `orient_codebase`, `verify_errors`, `audit_feedback`, `NC_DEV_BRANCH`. F1's relevance pack is adjacent to D's `orient_codebase` — some phases may merge on implementation.
- **Phase E — PLAN-v3.md Tier 1.** The `nightcrawler-planning` skill + `nightcrawler update` command. E would also prevent spec-hygiene issues (the over-strict "only X modified" ACs that caused half of NC-SMOKE's audit rejections).

Neither D nor E is reshaped by this plan. BCF is a grounding layer they both benefit from.
