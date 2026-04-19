# Plan: Pipeline Context Awareness

> Status: DRAFT (reviewed 2026-04-19 after Phase A + BCF — see compatibility pass below)
> Date: March 9, 2026
> Motivation: NC-221 (Camello) failed post-commit verification twice and locked — Sonnet re-implemented blind with zero error context. Broader audit shows multiple stages where useful information exists but isn't passed forward.

---

## Compatibility pass — 2026-04-19 (after Phase A + BCF)

This plan predates Phase A (streaming/envelopes, shipped) and PLAN-phase-bcf.md (queue reconciliation + structured audit contract + grounded companion). Per-phase verdicts:

| Phase / Gap | Verdict | Notes |
|---|---|---|
| **Phase 1 — Post-commit `verify_errors`** (D1) | **unchanged** | Streaming fixed blind timeouts *during* impl; did not fix blind re-implementation *after* post-commit revert. The `verify_errors.txt` plumbing still doesn't exist. Highest-value item in this plan and still first-class. |
| **Phase 2 — Audit feedback → impl** (D2) | **rewrite to consume B0** | B0 replaces raw `AUDIT_FEEDBACK` text with a structured contract. Inject `advisories[]`, `why_confident`, `what_would_change_my_mind` into `implement_task` — *not* the old flat text. |
| **Phase 3 — Full feedback history** (D3) | **unchanged (minor format update)** | BCF does not give revision loops intra-loop memory. `feedbacks[]` now holds structured B0 objects; rendering loop unchanged conceptually. |
| **Phase 4 — Session learnings → Codex** (D4) | **tombstoned — merged into F1** | Not a standalone phase. Becomes an implementation note under F1 (include session learnings file as an always-present pack entry). Body below is a one-paragraph tombstone; detailed spec preserved in git history. |
| **Phase 5 — Skip reasons in picker** (D5) | **trimmed — operator skips only** | C0 owns the shipped-task case. D5's remaining scope: operator-initiated skips (`skip NC-XXX <reason>` from Telegram or manual edits). Everything about the "already-done" case is removed. |
| **Phase 6 — Richer learnings** (D6) | **trimmed — learning synthesis only** | Reduced to post-task learning synthesis that consumes D1's `verify_errors.txt` + B0's structured audit + F1's `relevance_pack.meta.json`. Not a broad learnings initiative. Depends on D1 + B0 + F1 landing first. |
| **Phase 7 — Codebase orientation / `orient_codebase`** (D7) | **tombstoned — merged into F1** | Not a standalone phase. Becomes a "session-wide summary" cached once per session and prepended to every F1 pack. Body below is a one-paragraph tombstone; detailed spec preserved in git history. |
| **Phase 8 — Hardcoded Solidity refs** | **retired** | Fully retired from this plan. B0's per-project `audit-persona.md` is the canonical fix. |
| **Phase 9 — `NC_DEV_BRANCH` / multi-instance** (D9) | **unchanged** | Orthogonal to BCF. See also PLAN-v3.md Tier 3.3 (duplicate spec of the same feature) — consolidate the specification here, remove from v3 roadmap. |

**First-class after BCF:** D1, D3, D5 (trimmed to operator skips), D9. **Rewritten to consume BCF outputs:** D2. **Trimmed:** D6 (narrowed to learning synthesis). **Tombstoned — merged into F1:** D4, D7. **Retired:** D8.

**Ship order after BCF MVP (C0 + F1 + F5):** D1 first (standalone, highest value). Then D3 (no BCF dependency). Then D2 + D6 together (both need B0 to exist first). Then D9 (fully independent).

---

## Problem

The pipeline has **7 context gaps** where stages operate without information that earlier stages already produced. The worst one (post-commit revert → blind re-implementation) directly caused NC-221's lock. Others cause unnecessary iteration cycles, repeated mistakes, and wasted prompts.

### Context gaps by severity

| # | Gap | Impact | Example |
|---|-----|--------|---------|
| 1 | Post-commit build/test errors not passed to re-implementation | Task locks after 2 blind attempts | NC-221: Sonnet made the same mistake twice |
| 2 | Codex audit feedback not passed to implementation | Sonnet doesn't know what the auditor worried about | Auditor flags "watch for X" → Sonnet doesn't see it → reviewer catches it → extra cycle |
| 3 | Revision loops only see last feedback, not history | Can ping-pong between two fixes | Round 2 fixes A breaks B, Round 3 fixes B breaks A |
| 4 | Codex never sees session learnings | Repeats same review concerns across tasks | "Missing null check" flagged on tasks 3, 5, 7 — same pattern |
| 5 | Task picker doesn't know why tasks were skipped | Can pick tasks that will fail for the same reason | Skipped NC-221 for build error → picks NC-222 which depends on same broken pattern |
| 6 | Learnings generated from diff stats only | Misses the actual lesson (failure reason, reviewer concern) | Learning: "modified 3 files" vs what it should be: "i18n keys must match between en.json and es.json" |
| 7 | No codebase orientation before first task | Sonnet starts planning cold — must discover conventions during the planning turn | Wastes turns reading files that a pre-session scan could summarize |

---

## Design Principles

1. **Information flows forward, never lost** — every stage's output feeds the next stage's input
2. **Minimal prompt bloat** — context is summarized, not dumped raw. Truncation limits enforced.
3. **Backward compatible** — all new context is optional/additive. Missing files = no change to behavior.
4. **Deterministic bash stays deterministic** — new context is files on disk, not in-memory state

---

## Phase 1: Post-commit error feedback (Gap #1)

**The NC-221 fix.** Most impactful, smallest change.

### Changes

**`verify_post_commit()`** — capture build/test output to files:
```bash
verify_post_commit() {
    local task_id="$1" commit_hash="$2"
    local verify_dir="$SESSION_DIR/tasks/$task_id"
    cd "$PROJECT_PATH"

    set +e
    run_timed $BUILD_WALL $BUILD_IDLE $BUILD_CMD > "$verify_dir/build_output.log" 2>&1
    local b=$?
    run_timed $TEST_WALL $TEST_IDLE $TEST_CMD > "$verify_dir/test_output.log" 2>&1
    local t=$?
    set -e

    if [[ $b -ne 0 ]] || [[ $t -ne 0 ]]; then
        # Save which phase failed for the re-implementation prompt
        local error_summary=""
        if [[ $b -ne 0 ]]; then
            error_summary="BUILD FAILED:\n$(tail -50 "$verify_dir/build_output.log")"
        fi
        if [[ $t -ne 0 ]]; then
            error_summary="${error_summary}\nTEST FAILED:\n$(tail -50 "$verify_dir/test_output.log")"
        fi
        echo -e "$error_summary" > "$verify_dir/verify_errors.txt"
        return 1
    fi

    journal '{"event":"task_verified","task_id":"'"$task_id"'","commit":"'"$commit_hash"'"}'
    return 0
}
```

**`impl_loop()`** — accept optional initial feedback (3rd param):
```bash
impl_loop() {
    local plan_file="$1" task_id="$2" initial_feedback="${3:-}"
    local -a feedbacks=()
    # ... existing setup ...

    # If re-entering after post-commit failure, seed feedback array
    if [[ -n "$initial_feedback" ]]; then
        feedbacks+=("$initial_feedback")
    fi

    while (( iteration < MAX_IMPL_ITERATIONS )); do
        iteration=$((iteration + 1))

        if [[ $iteration -eq 1 ]] && [[ ${#feedbacks[@]} -eq 0 ]]; then
            # Fresh implementation
            implement_task "$plan_file" "$PROJECT_PATH" "$task_id"
        else
            # Revision (either from review feedback OR post-commit error)
            revise_impl "$plan_file" "${feedbacks[-1]}" "$iteration"
        fi
        # ... rest unchanged ...
```

**Main loop** — pass verification errors to re-implementation:
```bash
# Post-commit verification (around line 2107)
if ! verify_post_commit "$TASK_ID" "$commit_hash"; then
    revert_count=$((revert_count + 1))
    handle_post_commit_failure "$TASK_ID" "$commit_hash" "$revert_count"
    # ... existing lock check ...

    # Read the error context
    local verify_errors=""
    local error_file="$SESSION_DIR/tasks/$TASK_ID/verify_errors.txt"
    if [[ -f "$error_file" ]]; then
        verify_errors=$(cat "$error_file")
    fi

    # Re-enter impl_loop WITH error context
    impl_loop "$PLAN_FILE" "$TASK_ID" \
        "POST-COMMIT VERIFICATION FAILED (attempt $revert_count). Your previous implementation was reverted. Fix these errors:

$verify_errors"
```

**Revert cap**: 2 → 3 (one more chance now that attempts aren't blind).

### Files modified
- `scripts/nightcrawler.sh`: `verify_post_commit()`, `impl_loop()`, main loop post-commit block, `handle_post_commit_failure()`

---

## Phase 2: Audit feedback → implementation (Gap #2)

Codex audit feedback (even on APPROVED plans) often contains useful caveats like "watch for edge case X" or "make sure Y has null checks." Currently this is logged and discarded. Sonnet should see it.

### Changes

**`plan_loop()`** — save last audit feedback to file:
```bash
# After run_audit, regardless of verdict:
echo "$AUDIT_FEEDBACK" > "$SESSION_DIR/tasks/$task_id/audit_feedback.txt"
```

**`implement_task()`** — inject audit context into prompt:
```bash
# After loading plan, before building prompt:
local audit_notes=""
local audit_file="$SESSION_DIR/tasks/$task_id/audit_feedback.txt"
if [[ -f "$audit_file" ]]; then
    audit_notes="
AUDITOR NOTES (from the independent plan reviewer — pay attention to flagged concerns):
$(head -c 2000 "$audit_file")
"
fi

prompt="You are implementing a task...

PLAN (your primary source of truth):
${plan}
${audit_notes}
${learnings}
..."
```

### Files modified
- `scripts/nightcrawler.sh`: `plan_loop()` (1 line), `implement_task()` (8 lines)

---

## Phase 3: Full feedback history in revision loops (Gap #3)

Currently `revise_impl` receives only `${feedbacks[-1]}` (the last rejection). If a revision fixes issue A but reintroduces issue B from round 1, Sonnet has no memory of B.

### Changes

**`revise_impl()`** — accept full feedback history, format as numbered rounds:
```bash
revise_impl() {
    local plan_file="$1" feedback_history="$2" iteration="$3"
    # $feedback_history is already formatted by caller
    ...
    prompt="...
REVIEWER FEEDBACK HISTORY (all rounds — do not reintroduce previously fixed issues):
${feedback_history}
..."
```

**`impl_loop()`** — format and pass full history:
```bash
# Build formatted history
local feedback_history=""
for i in "${!feedbacks[@]}"; do
    feedback_history="${feedback_history}
--- Round $((i+1)) ---
${feedbacks[$i]}
"
done

# Truncate to 4000 chars to avoid prompt bloat
feedback_history="${feedback_history:0:4000}"

revise_impl "$plan_file" "$feedback_history" "$iteration"
```

Same treatment for `revise_plan()` in `plan_loop()`.

### Files modified
- `scripts/nightcrawler.sh`: `impl_loop()`, `revise_impl()`, `plan_loop()`, `revise_plan()`

---

## Phase 4: Session learnings → Codex — TOMBSTONE (merged into F1 on 2026-04-19)

Originally specced as a separate bolt-on to pipe session learnings into Codex audits. On review after BCF: not a standalone phase. The session's learnings file becomes one of the always-included entries in every F1 relevance pack. See `PLAN-phase-bcf.md` → Phase F1 for the canonical implementation.

No action required from this plan. Detailed original spec preserved in git history.

---

## Phase 5: Skip reasons in task picker (operator-initiated skips only)

**Scope narrowed 2026-04-19:** C0 (PLAN-phase-bcf.md) owns the "task is already shipped" case via deterministic `[ ]` → `[x]` reconciliation — not the skip file. D5's remaining scope is **operator-initiated skips**: when a human tells Nightcrawler to skip a task (via `skip NC-XXX <reason>` from Telegram or by editing `$CONTROL_DIR/skip` manually), capture and surface the reason so the picker avoids re-offering semantically-linked tasks.

### Changes

**Skip file format** — change from bare IDs to `ID: reason` (operator skips only):
```bash
# When an operator issues a skip command:
echo "$TASK_ID: $REASON" >> "$CONTROL_DIR/skip"
```

**`pick_next_task()`** — already reads the skip file into the prompt. No change needed — the picker will naturally see the reasons.

**Backward compat** — the task ID extraction regex (`grep -oP '^\S+'`) still works since the ID comes first.

### Files modified
- `scripts/nightcrawler.sh`: operator-skip call sites (exclude the post-commit-verify-failed auto-skip path — C0 covers that differently).
- OpenClaw bot / Telegram command handler for `skip <id> <reason>` input.

---

## Phase 6: Learning synthesis from BCF outputs (scope narrowed)

**Scope narrowed 2026-04-19:** reduced from a broad "richer learnings initiative" to **post-task learning synthesis** that consumes structured evidence the BCF pipeline already produces. Not a new context-gathering system. The learning prompt reads:

- **D1 output:** `verify_errors.txt` (post-commit build/test failures, if any)
- **B0 output:** the final-iteration structured audit/review — specifically `blocking_issues[]` (what was hard-rejected and fixed) and `irrelevant[]` (what the reviewer considered and chose to skip)
- **F1 output:** the corresponding `relevance_pack.meta.json` (what the reviewer actually looked at)

### Dependencies

Must land after D1 (verify_errors plumbing), B0 (structured contract), and F1 (pack + meta). Until all three exist, this is a no-op phase.

### Changes

**`capture_task_learning()`** — consume BCF artifacts rather than re-gathering context:

```bash
capture_task_learning() {
    local task_id="$1" commit_hash="$2"
    local task_dir="$SESSION_DIR/tasks/$task_id"

    # Pull structured evidence produced by BCF phases (read-only — no re-scanning)
    local verify_errors="" b0_audit="" f1_meta=""
    [[ -f "$task_dir/verify_errors.txt" ]]       && verify_errors=$(head -c 500 "$task_dir/verify_errors.txt")
    [[ -f "$task_dir/audit_final.json" ]]        && b0_audit=$(jq -c '{blocking_issues, irrelevant}' "$task_dir/audit_final.json")
    [[ -f "$task_dir/relevance_pack.meta.json" ]] && f1_meta=$(jq -c '.entries | map({file,reason}) | .[0:8]' "$task_dir/relevance_pack.meta.json")

    local learning_prompt="You just completed task $task_id.

Diff summary: $diff_stat

Verification errors (before fix): ${verify_errors:-none}
Structured audit (final iteration): ${b0_audit:-n/a}
Reviewer reading list: ${f1_meta:-n/a}

Write ONE line (max 120 chars) capturing the most useful technical insight this task produced. Prefer insights grounded in the audit's blocking_issues or irrelevant bucket over generic observations."
}
```

### Files modified
- `scripts/nightcrawler.sh`: `capture_task_learning()` consumes BCF artifacts, no new context gathering.

---

## Phase 7: Pre-session codebase orientation — TOMBSTONE (merged into F1 on 2026-04-19)

Originally specced as a standalone `orient_codebase()` producing a per-session `codebase_context.md` injected into every prompt. On review after BCF: not a standalone phase. Implemented instead as a "session-wide summary" cached once per session and prepended to every F1 relevance pack. Prevents two parallel context-builder projects (F1's selector + this one). See `PLAN-phase-bcf.md` → Phase F1 for the canonical implementation.

No action required from this plan. Detailed original spec preserved in git history.

---

## Phase 8: Hardcoded "Solidity/Foundry" references — RETIRED (2026-04-19)

Fully retired. Superseded by BCF B0, which replaces the hardcoded persona with per-project `config/projects/<project>/audit-persona.md`. See `PLAN-phase-bcf.md` → Phase B0.

No action required from this plan.

---

## Implementation Order (superseded — see consolidated table below after Phase 9)

*Original per-phase table removed 2026-04-19 after the compatibility pass retired Phase 8 and tombstoned Phases 4 and 7. Single consolidated table lives after Phase 9.*

---

## Phase 9: Configurable dev branch names (multi-instance support)

Multiple Nightcrawler instances on the same repo currently collide because `nightcrawler/dev` is hardcoded ~20 times in `nightcrawler.sh`, plus references in `start.sh` and recovery logic. Two concurrent sessions (e.g., two VPSes, or local + VPS) would push to the same branch and clobber each other.

### Design

New config variable `NC_DEV_BRANCH` in `.nightcrawler/config.sh`:
```bash
# .nightcrawler/config.sh
NC_DEV_BRANCH="nightcrawler/dev-vps1"   # default: "nightcrawler/dev"
```

If unset, falls back to `nightcrawler/dev` (backward compatible).

**Naming options** (user picks one in config):
- Manual: `nightcrawler/dev-vps1`, `nightcrawler/dev-local` — most readable
- Hostname-based: `nightcrawler/dev-$(hostname -s)` — auto-differentiates by machine
- Session-based: `nightcrawler/dev-$(date +%Y%m%d-%H%M)` — unique per run, but creates branch sprawl

Recommendation: manual naming (clearest for humans reading git log), with hostname as a documented alternative.

### Changes

**`nightcrawler.sh`** — replace all hardcoded `nightcrawler/dev` with `$DEV_BRANCH`:
```bash
# Near top, after config.sh is sourced:
DEV_BRANCH="${NC_DEV_BRANCH:-nightcrawler/dev}"

# All ~20 occurrences change from:
git checkout nightcrawler/dev
git push origin nightcrawler/dev
# To:
git checkout "$DEV_BRANCH"
git push origin "$DEV_BRANCH"
```

Affected locations (grep `nightcrawler/dev` in nightcrawler.sh):
- `setup_branch()` — creates/checks out the branch
- `commit_and_close_task()` — pushes after commit
- `handle_post_commit_failure()` — revert on branch
- `main_loop()` — initial checkout
- `cleanup()` / `graceful_stop()` — branch state on exit
- Journal entries and log messages that mention the branch name

**`start.sh`** — same treatment:
```bash
# Source config first, then:
DEV_BRANCH="${NC_DEV_BRANCH:-nightcrawler/dev}"
# Replace hardcoded references in pre-flight checks
```

**`nightcrawler-init.sh`** — add `NC_DEV_BRANCH` to generated config.sh (commented out, showing default):
```bash
# NC_DEV_BRANCH="nightcrawler/dev"  # Uncomment to customize (for multi-instance)
```

### Migration
- No migration needed — default is `nightcrawler/dev` (same as current behavior)
- Existing sessions on `nightcrawler/dev` keep working
- New instances just set `NC_DEV_BRANCH` in config

### Files modified
- `scripts/nightcrawler.sh`: ~20 replacements of `nightcrawler/dev` → `$DEV_BRANCH`, plus variable declaration
- `scripts/start.sh`: ~2-3 replacements
- `scripts/nightcrawler-init.sh`: add commented `NC_DEV_BRANCH` to generated config template

---

## Implementation Order (post-2026-04-19 cut list)

| Phase | Gap | Risk | Effort | Dependencies |
|-------|-----|------|--------|-------------|
| 1 | Post-commit error feedback (verify_errors.txt) | LOW | Small | None |
| 2 | Audit feedback → impl (consumes B0 `audit_final.json`) | LOW | Small | BCF B0 |
| 3 | Full feedback history | LOW | Small | Phase 2 |
| 5 | Operator-initiated skips (with reason) | LOW | Tiny | None |
| 6 | Learning synthesis | LOW | Small | Phase 1, 2; BCF B0 + F1 |
| 9 | Configurable dev branch (NC_DEV_BRANCH) | LOW | Small | None — canonical spec lives here |

Phases 1, 5, 9 are independent — can be implemented in any order or parallel.
Phase 2 depends on BCF B0 shipping first (needs the structured audit JSON).
Phase 3 depends on Phase 2 (reuses the same JSON files).
Phase 6 depends on Phases 1-2 and BCF B0+F1 (reads their output files).

**Retired / tombstoned (not in this table):**
- Phase 4 — merged into F1 relevance pack.
- Phase 7 — merged into F1 (session-wide summary cached once per session).
- Phase 8 — retired; superseded by BCF B0 per-project audit persona.

---

## Testing

1. **Syntax check**: `bash -n scripts/nightcrawler.sh` + `python3 -m py_compile scripts/call_codex.py`
2. **Dry run**: `start.sh <project> --budget 1 --dry-run` — exercises plan + audit with new context
3. **Single task**: `--budget 3` on a known-failing task (one that triggers post-commit revert) to verify error feedback flows
4. **Multi-instance**: Run two sessions with different `NC_DEV_BRANCH` values on the same repo — verify no branch collision
5. **Full session**: `--budget 0` overnight, compare task completion rate vs previous sessions

(Testing for tombstoned phases — 4/7/8 — is no longer relevant; see BCF for F1/B0 test coverage.)

---

## What This Doesn't Change

- Pipeline structure (plan → audit → implement → review → commit → verify)
- Codex as independent reviewer (still separate from Sonnet)
- Budget system, degraded mode, convergence detection
- Session learnings format (still 1-line per task, still async)
- RULES.md / CLAUDE.md injection points
