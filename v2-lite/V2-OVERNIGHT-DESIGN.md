# Nightcrawler v2-overnight — Feat-Runner Design

**Status:** Draft for review · **Date:** 2026-06-08 · Depends on: v2-lite (proven 2026-06-08)
**Goal:** hand it a *feature* (a unit of work too big for one task), walk away, check one report at the end.

This is the tier the main spec deferred. v2-lite is the unit loop (one task → one verdict). v2-overnight
orchestrates *many* v2-lite runs into a feature, with the guarantees a multi-task run needs that a single
task doesn't. **Auto mode removes prompts — it does NOT remove these boundaries.**

---

## 1. What changes from v2-lite

v2-lite already gives: per-task plan→implement→Codex-review→fix→verify, bounded, with a hard infra guard,
in an isolated worktree, returning one structured verdict. The feat-runner **reuses that loop unchanged**
per task and adds the layer above it. The new guarantees (Codex's list, expanded):

| Concern | v2-lite | v2-overnight adds |
|---|---|---|
| Scope | one task | a **feat** = a set of tasks |
| State | in-run (script vars) | **persistent feat state** (survives crash/quit/resume) |
| Ordering | n/a | **task DAG** with dependencies |
| Identity | per-task worktree id (FNV of task) | **deterministic task IDs** + one **feat branch** |
| Integration | per-task verify | **final integration verify** on the merged feat branch |
| Output | one verdict | one **feat report** (per-task status + integration result) |
| Recovery | resume within session | **resume the feat**: re-run only incomplete tasks |

---

## 2. Branch & worktree model

The integrity rule from v2-lite carries up: identity is **owned by the runner, never improvised**.

- One **feat branch** `nc/feat-<featId>` cut from the base branch at feat start. `featId` = deterministic
  hash of the feat spec.
- Each task runs the **v2-lite loop in its own worktree**, branched from the *current feat branch* (so a
  task sees its dependencies' merged work).
- On task `done` (Codex clean + verify pass), its branch **merges into the feat branch**. On any non-done
  status, it does **not** merge — it's surfaced and its dependents are blocked.
- Nothing touches the base branch. The human reviews/merges the feat branch at the very end.

Open question: merge-conflict handling between sibling tasks (see §6).

---

## 3. Execution model

1. **Intake → decomposition.** A feat spec becomes an ordered **task DAG**: nodes are v2-lite tasks, edges
   are dependencies. (M1: human-authored task list. Later: a planner agent proposes the DAG, adversarially
   reviewed before it runs — same closed-loop discipline.)
2. **Schedule.** Run tasks whose dependencies are all `done`. Independent tasks may run in parallel, bounded
   by the runtime's 16-concurrent / 1000-total agent caps **and** a feat-level concurrency limit (each task
   is itself several agents, so the real ceiling is lower).
3. **Per task:** invoke the v2-lite loop (unchanged). On `done` → merge into feat branch, mark node done.
   On `review_unresolved` / `verify_failed` / `infra_error` → mark node failed, **block its dependents**,
   keep independent branches going.
4. **Integration verify.** After the DAG drains, run the **verifier once on the integrated feat branch**.
   This catches cross-task breakage that green per-task verifies individually miss — the single most
   important thing per-task gates can't give you.
5. **Report.** Emit one structured feat report: per-task status, what merged, what's blocked and why, the
   integration-verify result, and the feat branch to review.

---

## 4. Stop conditions (the brakes that auto mode must not collapse)

- A task that exhausts its v2-lite ROUND_CAP / fails verify / hits infra → **does not merge**, blocks
  dependents. The feat does not "push through" a failed task.
- **Feat-level caps:** max tasks, max review/fix rounds across the feat, and a wall-clock / rate-limit
  ceiling. When hit → stop, report partial progress, never silently continue.
- **Integration verify is non-negotiable:** all-tasks-green does NOT mean feat-done; the merged branch must
  pass the verifier. A clean DAG with a red integration verify → `feat_integration_failed`.
- Auto mode's own fallback (pause after repeated classifier blocks) is a backstop, not the brake.
- **No self-mutation mid-feat:** the runner, skill, verifier, schemas, and permission rules are **frozen**
  for the duration of a run; the loop never edits its own brakes while driving. Improvements are proposed as
  tasks for a later maintenance run (see §8).

---

## 5. Persistent feat state & recovery

- Feat state lives in a file (e.g. `~/.claude/nightcrawler/feats/<featId>.json`) — **outside** any worktree,
  same tamper-proofing as the gate scripts. Holds the DAG, each node's status, the merged set, and the
  feat branch ref.
- **Deterministic task IDs** (hash of task spec) make resume safe: a resumed feat reads state, skips `done`
  nodes, re-runs only incomplete ones. No Math.random / Date anywhere (the v2-lite determinism gotcha
  applies to the whole layer).
- A crash mid-task leaves that task's worktree unmerged; resume re-runs that task cleanly (its worktree is
  recreated deterministically or cleaned first).

---

## 6. Open questions (decide before building, not during)

1. **Decomposition authority** — human-authored task list (M1) vs a planner agent that proposes the DAG.
   If agent: the DAG itself should pass an adversarial review before execution (closed loop on the plan).
2. **Sibling merge conflicts** — two independent tasks editing nearby code. Options: serialize on file
   overlap (detect from each task's `files_changed`), or detect conflict at merge and route a resolve task.
3. **Parallelism ceiling** — each task is N agents; need a feat concurrency limit well under the 16-cap.
4. **Where feat state lives** — per-user (`~/.claude/...`) vs per-repo. Per-user keeps it out of the repo
   and tamper-proof; per-repo makes it reviewable in a PR. Lean per-user for now.
5. **What "feat done" reports to the human** — branch to merge, or auto-open a PR? Keep merge human for now.

---

## 7. v1 contracts to port (the contracts, not the bash)

This layer is where v1's multi-task machinery earns its place — ported as workflow logic / state, not bash:
queue selection (→ DAG schedule), dependency handling (→ DAG edges), ghost-commit guard (→ "task marked
done but nothing merged" check), journal/events (→ feat state + report), crash recovery (→ resumable state).
Port each **only when the feat-runner actually needs it**, per the v1 lesson (don't over-build ahead of use).

---

## 8. Continuous improvement / retrospective loop

Every feat run ends with a **structured retrospective report** — beyond the pass/fail summary of §3, it
captures the calibration data: per-task outcomes, Codex review findings, verifier failures, blocked
dependents, review/fix retries, infra failures, token & agent usage, suspected **false positives** (findings
that were wrong or noise), and a "what slowed this down" narrative.

From that report the runner **may emit improvement candidates as backlog items — never auto-applied.** Each
candidate must:

- **Target a specific surface:** `SKILL.md`, `review-prompt.md`, `sev.schema.json`, `verify.py`, the
  workflow JS, the allowlist config, or feat-runner logic. "Make it better" is not a candidate.
- **Carry evidence** — a concrete observation, not a vibe: *"this task failed verify twice because the
  detector missed the monorepo's test script", "Codex flagged schema drift on `priority` three times",
  "review false-positived on generated files."* No evidence → no candidate.

**Improvements to Nightcrawler itself go through Nightcrawler's own gate** — tests + Codex review +
deterministic verify. The system improves itself only through the same closed loop it runs on everything
else. (This whole session *was* that loop, run by hand: Codex caught the schema-strictness 400, the
`verdict`/`status` mismatch, and the `Math.random` resume break — each fixed under test + review. The retro
loop just formalizes it.)

### Hard rule — no self-mutation while driving

> Nightcrawler may **learn** from reports, but it may **not mutate its own runner, skill, verifier, schemas,
> or permission rules during a feat run.** It can only **propose improvement tasks for a later, explicit
> maintenance run.**

A system that rewrites its own brakes mid-drive has no brakes. Calibration is a separate, human-initiated
maintenance feat — itself gated like any other.

**Mental model:** reports → calibration tasks → an improved loop → the next feat handled better. Compounding
quality, with the safety property that the loop in force during any run is always a frozen, reviewed one.

---

## 9. Milestones (incremental — prove each before the next)

- **M1 — sequential feat.** Human-authored ordered task list, no parallelism, no auto-decompose. Run v2-lite
  per task → merge into one feat branch → integration verify → report. Proves the feat-branch + integration
  shape with the least new surface. **Build this first.**
- **M2 — DAG + bounded parallelism.** Dependencies + a few parallel independent tasks under a feat
  concurrency cap.
- **M3 — auto-decompose.** A planner agent proposes the DAG from a feat spec; the DAG is adversarially
  reviewed before running.
- **M4 — resilience.** Persistent state + feat resume + sibling-conflict handling.
- **M5 — calibration loop (§8).** Retro reports emit evidence-backed improvement candidates; a separate,
  human-initiated maintenance feat applies them through the standard gate. Build only once real runs have
  generated real signal — do **not** synthesize calibration data (the v1 "don't tune without traffic" lesson).

Decision gate after M1: does a sequential feat-runner beat just running v2-lite by hand per task? Only build
M2+ if it does — same discipline that gated v2-lite over plain `/goal`.

---

*The feat-runner is v2-lite's loop wrapped in a scheduler and an integration gate. The unit stays honest
(Codex + verify per task); the feat stays honest (integration verify + stop conditions). Auto mode just
means you're not clicking — every gate still fires.*
