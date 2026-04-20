---
plan: F5 — Shipped-task awareness (companion-side)
status: draft v2 (review)
phase: BCF / MVP
depends_on: C0 (shipped), F1 (shipped), F2 (shipped)
gated_by: NC_COMPANION_CHECK (default on, set NC_COMPANION_CHECK=0 to disable). Validated 2026-04-20 on n=6 probes.
---

**v2 changes from v1 review:**
- **P1 fix.** PARTIAL context now augments the session-dir task_file
  (read by planner AND auditor), not a planner-only prompt header.
  Prevents auditor from rejecting legitimate partial-work plans for
  "not addressing" already-shipped AC bullets.
- **P2 fix.** SHIPPED writes to the existing `CONTROL_DIR/skip`
  channel that `pick_next_task` already reads. No new parameter, no
  in-memory set, no duplicate exclusion mechanism. Crash/resume
  persistence comes for free.


# F5 — Shipped-task awareness (companion-side)

## Problem

C0 is the scheduler-side deterministic guard: it walks
`merge-base(main, nightcrawler/dev)..nightcrawler/dev`, extracts task IDs
from trailers, subject parens, and `Task:` lines, and flips `[ ]` → `[x]`
when it finds a match. It is the hard correctness floor and it works.

C0 cannot see three failure modes, all of which cost real tokens when they
fire:

1. **Commit without a task-ID hook.** The AC-satisfying code was landed
   inside a *different* task's commit (multi-task landing, refactor sweep,
   cleanup commit). No trailer, no `feat(NC-XXX)`, no `Task:` line for the
   target ID.
2. **Out-of-range code.** The work landed before the current merge-base
   (direct to `main`, pre-Nightcrawler work, older branch that merged
   cleanly). C0's scan range doesn't reach it.
3. **Partial shipment.** Half the AC already exists. C0 has no "partial"
   concept, so the picker proceeds and the planner proposes a clean-slate
   implementation instead of an incremental one.

F5 is the companion-side soft check that catches these. Deterministic
state changes still belong to C0. F5 produces **signal**, never mutation.

## Design

### Fire point

`main_loop` today, after `verify_task_not_shipped` returns 0:

```
main_loop
├── reconcile_queue                   (C0 pre-pick)
├── pick_next_task
├── verify_task_not_shipped (×3)      (C0 post-pick)
├── companion_shipped_check  ←── F5 slots here
├── budget_pre_check
└── plan_task
```

F5 runs once per task per iteration. On re-pick, F5 re-runs against the
new task. SHIPPED verdicts append the task_id to `$CONTROL_DIR/skip`,
which `pick_next_task` already consults, so a shipped task won't be
picked again this session.

### Pack: `shipped_check` phase

**Same candidate selector as `plan_audit`.** No new ranker surface. The
existing ranker is already good at pulling task-relevant files — that's
exactly what F5 needs to read for existence evidence.

**Different assembly.** The pack is built for a different question
("does this already exist?"), so it carries different context:

| Block | Content | Source |
|---|---|---|
| task_spec | Full task body as-is | `TASK_QUEUE.md` |
| file_excerpts | Top-ranked files from plan_audit selector, per-file cap 2500B | Ranker output |
| file_history | `git log --all --oneline -5 -- <selected_files>` per file | Full-history, NOT merge-base-bounded |
| evidence_snippets | For each file history entry: first matching hunk (≤200B) from the commit that touches it | `git log -p` |

No full diffs. No full logs. The "last 1-3 matching commits/snippets"
rule sits in the evidence_snippets block.

Total budget parity with `plan_audit` (~20KB ceiling). If `file_history`
+ `evidence_snippets` crowd out `file_excerpts`, the ranker's
truncate-to-fit policy keeps the pack useful rather than discarded.

### Contract (JSON, strict)

F5 returns structured JSON, same spirit as the B0 v2 auditor contract.
Prose-only was rejected — structured makes this debuggable from the
journal alone.

```json
{
  "schema_version": 1,
  "verdict": "NOT_SHIPPED | SHIPPED | PARTIAL | UNCERTAIN",
  "confidence": "high | medium | low",
  "summary": "≤2 sentences in human English",
  "evidence": [
    {
      "kind": "commit | file | snippet",
      "ref": "sha|path|path:line",
      "note": "why this supports the verdict"
    }
  ],
  "open_questions": [
    "aspect of the AC the pack can't answer"
  ]
}
```

Evidence is required on `SHIPPED` and `PARTIAL`. `open_questions` is
required on `UNCERTAIN` and `PARTIAL` (since partial implies something
unclear about remaining work). Both are optional on `NOT_SHIPPED`.

### Routing

| Verdict | Orchestrator action |
|---|---|
| `NOT_SHIPPED` | Proceed to `plan_task` normally. Journal `companion_shipped_check` event with verdict + confidence. |
| `UNCERTAIN` | Proceed to `plan_task`. Journal the event. Task file is not modified. |
| `PARTIAL` | Rewrite the session-scoped task_context file with existing-work header (see below), then proceed to `plan_task`. Planner AND auditor both read the augmented file. Journal event with evidence + open_questions. |
| `SHIPPED` | Abort this iteration. Journal `companion_shipped_signal` with evidence. Telegram-notify operator with summary + SHAs. Append task_id to `$CONTROL_DIR/skip` (the existing picker skip channel). Re-pick. |

**No queue mutation.** SHIPPED never flips `[ ]` → `[x]`. Operator, or
the next `/reconcile` pass, decides.

**Session skip reuses the existing channel.** The scheduler already has
`CONTROL_DIR/skip` (one task ID per line), and `pick_next_task` already
reads it. On SHIPPED, F5 appends the task_id to that file. No new
parameter, no in-memory set. This gives crash/resume persistence for
free — if the session crashes and `nightcrawler resume` fires, the
skip file is still on disk and the same task won't get re-flagged by
F5's Sonnet call.

**Stale-pick counter shared with C0.** `verify_task_not_shipped`
returning 1 and F5 returning `SHIPPED` both increment the same counter.
After 3 total stale picks, session ends with operator escalation.

### PARTIAL injection (augment the task-context file, not the prompt)

On `PARTIAL`, the orchestrator writes an augmented version of the
existing session-scoped task-context file:

```
$SESSION_DIR/tasks/<task_id>/task_context.md   ← file on disk (unchanged name)
```

This is the file that `extract_task_context()` creates at
`nightcrawler.sh:2778-2780`, and it is the exact path already passed
through `plan_loop()` → `plan_task()` → `run_audit()` /
`revise_plan()` / `run_impl_review()` as the `task_file` parameter.
(The parameter name in the bash code says `task_file`; the file on
disk is `task_context.md`. F5 writes to the on-disk name and does not
rename anything.)

The augmentation flow:

1. `cp task_context.md task_context.original.md` (preserve original for forensics).
2. Write the augmented version over `task_context.md`.
3. Proceed to `plan_task`. Every downstream consumer picks up the
   augmented spec automatically — no callsite changes needed beyond
   the write.

Writing to the one file both planner and auditor already read means
the auditor compares the incremental plan against the same AC the
planner saw. Without this shape, the auditor would flag legitimate
partial-work plans for "not addressing bullet #2" — the P1 failure
Mateo caught in v1.

The augmented file layout:

```
EXISTING WORK DETECTED — BUILD INCREMENTALLY ON THIS:

<summary from F5 JSON>

Concrete evidence:
- <evidence[0].kind> <evidence[0].ref> — <evidence[0].note>
- <evidence[1].kind> <evidence[1].ref> — <evidence[1].note>
- …

Open questions from the shipped-check:
- <open_questions[0]>
- <open_questions[1]>

Both planner and auditor: your job is to extend the existing work, not
restart it. AC bullets that the evidence above already satisfies must
be marked as "shipped — verify only" in the plan, and must not be
flagged as plan gaps in audit.

---

<original task spec unchanged below this line>
```

- Original `TASK_QUEUE.md` is never modified by F5.
- The session-dir `task_context.md` is already per-iteration; on
  re-plan loops, the augmented file persists (correct — planner and
  auditor both keep the same context).
- Easy to ablate: restore from `task_context.original.md` and
  everything falls back to the original path.
- Clear in the journal: `companion_partial_inject` event names the
  augmented file path so forensics can `diff task_context.md
  task_context.original.md` after the fact.

## Integration points

### New files

- `scripts/lib/companion/shipped_check.py` — assembles the pack and
  returns the JSON. Calls `claude` (Sonnet) via the existing streaming
  accumulator. Pure Python, no new deps.
- `scripts/lib/companion/prompts/shipped_check.system.md` — the system
  prompt text ("You evaluate one question only: IS THIS TASK ALREADY
  IMPLEMENTED?"). Kept as a file so it can be diffed without touching
  Python.

### Modified files

- `scripts/lib/relevance_pack.py` — add `shipped_check` as a recognized
  `phase` value. Assembly branches on phase; selector is shared with
  `plan_audit`.
- `scripts/nightcrawler.sh`:
  - New `companion_shipped_check()` function (bash wrapper that invokes
    the Python helper, parses JSON result, routes on verdict).
  - Call site in `main_loop` between `verify_task_not_shipped` and
    `budget_pre_check`.
  - On `PARTIAL`: copy original `task_context.md` to
    `task_context.original.md` (same session dir), then write the
    augmented version over `task_context.md` — the canonical file
    consumers already load. Done once, before `plan_task` reads it.
    Planner, auditor, `revise_plan`, and `run_impl_review` all pick up
    the augmented spec automatically (no callsite changes).
  - On `SHIPPED`: append `task_id` to `$CONTROL_DIR/skip` (no new
    parameter — `pick_next_task` already reads this file).
  - Stale-pick counter in `main_loop` increments on both C0-stale and
    F5-SHIPPED.
- `scripts/call_sonnet.py` (or equivalent) — reused as-is. F5 uses the
  same streamed-Sonnet path.
- `pick_next_task` — no signature change. Existing `CONTROL_DIR/skip`
  read path is the only skip channel.

### Journal events

```
companion_shipped_check   { task_id, verdict, confidence, evidence_count, open_questions_count, ts }
companion_shipped_signal  { task_id, summary, evidence: [{kind, ref, note}, …], skip_file, ts }
companion_partial_inject  { task_id, summary, evidence_count, augmented_task_file, ts }
companion_uncertain       { task_id, summary, open_questions_count, ts }
```

All events include `task_id` and `ts`. `companion_shipped_signal` carries
the full evidence list because that's what the operator will look at in
Telegram, plus `skip_file` so forensics can confirm the skip was written.
`companion_partial_inject` carries `augmented_task_file` (path) so the
exact text the planner/auditor saw is recoverable.

## Failure modes & mitigations

| Failure | Mitigation |
|---|---|
| F5 hallucinates SHIPPED on a clean task | Structured evidence required; operator review via Telegram before any flip. No state mutation. |
| F5 misses a genuine shipped case (false NOT_SHIPPED) | C0 already catches most; plan auditor catches the rest with high confidence ("this AC is already met"). F5 is one layer, not the only layer. |
| F5 adds ~20-25s latency on every task | Measured on n=5 probes 2026-04-20. Post-cap SLO: p50 <= 20s, p95 <= 25s, no single call > 25s. See Acceptance. |
| F5 burns a Sonnet call on trivial tasks | Accepted for MVP. Cost review after 5 runs. Bypass heuristic later if needed — **must be a cheap bash pre-check (e.g., task body <300 chars, zero file hints), NOT `complexity_tier`**, because tier is produced by the plan auditor which runs *after* F5. |
| Same task picked-skipped-picked loop | Append to existing `$CONTROL_DIR/skip` file (one ID per line) — `pick_next_task` already reads it. Survives crash/resume. Shared stale-pick counter ends session after 3. |
| Pack assembly fails or Sonnet call errors | F5 returns `UNCERTAIN` with `error:` note on `open_questions`. Pipeline proceeds to plan — F5 is advisory, a broken F5 must not block work. |

## Acceptance

- **Unit:** `scripts/lib/companion/shipped_check.py` has pytest tests that feed
  synthetic packs (shipped/partial/not-shipped/uncertain fixtures) and
  assert the JSON contract.
- **Live probe (post-MVP, on next organic camello task):** F5 runs,
  returns `NOT_SHIPPED` with high confidence on a clean task, 1 Sonnet
  call. Latency SLO (post-F5.4d response cap): p50 <= 20s, p95 <= 25s,
  no single call > 25s. The hard <20s ceiling was revised after n=5
  probes showed per-call Sonnet jitter (~2-5s fixed overhead spread)
  dominates once response-size caps are in place; tightening caps
  further trades evidence quality for <=1-2s of mean, which does not
  resolve variance-driven breaches. No false positive.
- **Adversarial:** queue a task whose AC is satisfied by an existing
  commit that has no matching task-ID trailer/subject (cross-task
  landing). C0 misses, F5 catches, operator receives Telegram, task
  skipped, next task picked cleanly.
- **Partial:** queue a task where 1 of 3 AC bullets is already
  implemented. F5 returns `PARTIAL`, rewrites `task_context.md` in the
  session dir, plan and audit both reason against the augmented spec,
  audit does NOT reject for "unaddressed bullet #2", plan explicitly
  builds on existing work.
- **Cost:** first 5 real runs stay under 15% overhead on total task
  cost. If over, bypass heuristic goes in before further real traffic.

## Rollout

- `NC_COMPANION_CHECK` env flag, default **on** (2026-04-20, post-F5.4d
  cap + SLO revision). Set `NC_COMPANION_CHECK=0` to disable per-session.
  Historically was default off until validated on n=6 probes — see commit
  history for evolution (F5.4a/b/c/d + SLO commit 8f9dc8b).
- Turn on for one session against camello as the first live probe.
- Compare against F1 canary pattern: journal the 4 event types, inspect
  verdict distribution + confidence distribution + latency + cost.
- If next clean-quality sample lands within the SLO (p50 <= 20s,
  p95 <= 25s, no > 25s), flip default to on in VPS config. Current
  probe data: n=5 (NC-392/393/394 pre-cap, NC-395/396 post-F5.4d cap).
  Post-cap samples: 20523ms, 24641ms — within revised SLO.
- If noisy or slow, keep behind flag and decide whether to refine pack
  assembly or add bypass heuristic.

## What this plan deliberately does NOT do

- **No second ranker.** Same selector as `plan_audit`. If F5 misses
  shipped work because the selector didn't pick the right file, that's
  the trigger to revisit candidate selection — not to build it twice.
- **No queue mutation.** F5 can be wrong without corrupting state.
- **No retroactive scan.** F5 does not go back and re-check already-picked
  tasks. Fires at pick-time, once.
- **No auto-flip on SHIPPED.** The plan in `PLAN-phase-bcf.md` mentions
  "rerun C0 reconcile" as a SHIPPED action. Dropped: C0 uses regex /
  trailers, F5 fires precisely where those miss, so rerunning C0 is a
  no-op. Telegram + re-pick is the action.
- **No `complexity_tier` bypass.** Tier is a plan-auditor output and
  doesn't exist at F5's fire point. If a bypass lands later, it's a
  bash heuristic on the task body.

## Open questions for review

1. **Telegram format.** On SHIPPED, what does the message look like?
   Proposal: `F5 flagged NC-XXX as shipped: <summary>. Evidence: <sha1>, <sha2>. Added to CONTROL_DIR/skip for this session — run /reconcile to confirm and flip the queue.`

*(Dropped: session-skip persistence — resolved by reusing
`CONTROL_DIR/skip`. Prompt location confirmed:
`scripts/lib/companion/prompts/shipped_check.system.md`.)*
