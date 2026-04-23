# B4.2 steer-on validation plan

**Status:** pending · 2026-04-23
**Predecessor:** `project_bcf_closed.md` (deferred item "B4.2 default-on — waiting on inflation fire"), NC-427 fire in session `20260422…014905-camello`
**Scope:** one flagged session, observe the steer branch on a real fire, decide default-on only after a clean outcome.

---

## Background

B4.1 (plan inflation guard, observe-only) has been running since its validation run on 2026-04-22 and has produced one genuine fire: NC-427 in session `20260423-014905-camello`, where the planner grew the mini_plan from ~16.3 KB to ~24.6 KB across 4 iterations (51 % growth from initial, 7 % iter-over-iter at the detection point). B4.1 journaled `plan_inflation_detected` with `repeated_blocker: false` — i.e. the size-mode branch of the detector.

B4.2's steer prompt (commit `d4c6be9`) is shipped but gated behind `NC_PLAN_INFLATION_GUARD=1` (default off). Task #80 (the initial validation) ran the flag on a synthetic / non-firing session, which only exercised the no-fire path. We now have a natural fire to exercise the steer branch against.

Mateo's explicit posture: do **not** flip the default on based on observation alone. One real fire, clean outcome, then consider flipping.

## What this plan ships

Nothing. This is a validation pass. No code changes.

## Procedure

1. Wait for the next natural Camello session (product work queued by Mateo). Do not author synthetic tasks to force this — same rule as `feedback_nightcrawler_tuning.md`.
2. Start the session with `NC_PLAN_INFLATION_GUARD=1` exported in the environment. Everything else unchanged.
3. Let it run. When it finishes, filter the journal:
   ```
   jq -c 'select(.event == "plan_inflation_detected" and .steer_injected == true)' \
     $SESSION_DIR/journal.jsonl
   ```
4. For each matching task, pull:
   - `tasks/<ID>/plan_history.jsonl` (per-iteration size + top blocker subject)
   - `tasks/<ID>/mini_plan.md` (final plan that shipped)
   - Relevant verify_*_attempt_N.log entries
5. Read the steer-injected iteration's output against the iteration immediately prior. Compare against the B4.1 baseline: how much did the plan move? What did it change? Did the next auditor round accept, reject-same-blocker, or reject-new-blocker?

## Success criteria

All three must hold for one real fire to count as "clean":

1. **Auditor still blocks until the issue is actually fixed.** The steer must not cause the auditor to accept a plan that still has the original blocker. If the steer accelerated acceptance of broken plans, that's worse than the B4.1 baseline and a rollback signal.
2. **Next revised plan is materially tighter than the B4.1 baseline.** In the NC-427 baseline, iter 4's plan grew 7 % from iter 3 while still failing the same blocker family. A clean steer-on fire should produce a revised plan whose size delta is noticeably smaller (or negative — a narrowing revise) AND whose blocker subject is either resolved or materially different from the previous iteration's.
3. **No broad rewrite when the blocker is narrow.** If the steered plan rewrites sections unrelated to the active blocker — e.g., reworks the file list or scope statement when the blocker was about a single AC — that's a scope-preservation failure and a rollback signal. The repeat-mode branch of the steer is designed around this exact concern; we want to confirm size-mode also respects it.

## What to do with the outcome

- **All three hold, one real fire:** open a follow-up task to flip `NC_PLAN_INFLATION_GUARD` default on. Not part of this validation.
- **One or two hold, edge cases:** hold the default off, log the findings, wait for a second fire before deciding. Don't tune the steer prompt on a single data point.
- **None hold, or the steer made things worse:** revert / disable the steer on that branch type (size-mode vs repeat-mode are independent — either can be rolled back alone). Open a separate task to rework the prompt.

## Non-goals

- Tuning the inflation detection thresholds. If the detector fires wrong (false positive), that's a separate issue from whether the steer works once it fires.
- Flipping the default on preemptively.
- Authoring synthetic tasks to force more fires.
- Expanding the validation to multiple projects. Camello alone is fine for one data point; clout validation is a separate pass if ever needed.

## Out of scope (parallel tracks, not blockers)

- **#64 picker hallucination guard** shipped as `c38b58c` — independent, already live as of 2026-04-23.
- **Planner `error_max_turns` on real tasks** (NC-426, NC-428 in the same session) is a separate diagnosis track. Not conflated with this validation.
