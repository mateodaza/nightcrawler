# Plan: Pipeline Context Awareness

> Status: DRAFT
> Date: March 9, 2026
> Motivation: NC-221 (Camello) failed post-commit verification twice and locked — Sonnet re-implemented blind with zero error context. Broader audit shows multiple stages where useful information exists but isn't passed forward.

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

## Phase 4: Session learnings → Codex (Gap #4)

Codex auditor and reviewer operate in isolation — they don't see patterns from earlier tasks. If task 3 discovered "always validate i18n keys exist in both locales," the reviewer for task 5 should know that.

### Changes

**`call_codex.py`** — accept `--learnings` flag:
```python
def audit_plan(plan_file, task_file, rules_file, project_path=None, learnings_file=None):
    learnings = ""
    if learnings_file and Path(learnings_file).exists():
        learnings = Path(learnings_file).read_text()[:2000]

    # Inject into prompt:
    audit_prompt = f"""...
SESSION LEARNINGS (patterns discovered in earlier tasks this session — factor these in):
{learnings}

MINI-PLAN TO AUDIT:
..."""
```

Same for `review_impl()`.

**`nightcrawler.sh`** — pass learnings file to call_codex.py:
```bash
# In audit_plan_call():
python3 "$SCRIPTS/call_codex.py" audit-plan \
    --plan "$plan_file" \
    --task-file "$task_file" \
    --rules "$STATE_DIR/RULES.md" \
    --project "$PROJECT_PATH" \
    --learnings "$LEARNINGS_FILE"

# In review_impl():
python3 "$SCRIPTS/call_codex.py" review-impl \
    --project "$PROJECT_PATH" \
    --plan "$plan_file" \
    --rules "$STATE_DIR/RULES.md" \
    --learnings "$LEARNINGS_FILE"
```

### Files modified
- `scripts/call_codex.py`: `audit_plan()`, `review_impl()`, argparse
- `scripts/nightcrawler.sh`: `audit_plan_call()`, `review_impl()`

---

## Phase 5: Skip reasons in task picker (Gap #5)

Currently the skip file is just task IDs. The picker sees "NC-221 was skipped" but not why. Adding the reason helps it avoid picking tasks that will fail for the same reason.

### Changes

**Skip file format** — change from bare IDs to `ID: reason`:
```bash
# In main loop, when skipping a task:
echo "$TASK_ID: post-commit verify failed 2x (build error in i18n keys)" >> "$CONTROL_DIR/skip"
```

**`pick_next_task()`** — already reads the skip file into the prompt. No change needed — the picker will naturally see the reasons.

**Backward compat** — the task ID extraction regex (`grep -oP '^\S+'`) still works since the ID comes first.

### Files modified
- `scripts/nightcrawler.sh`: all `echo "$TASK_ID" >> "$CONTROL_DIR/skip"` lines (~8 occurrences) — append reason

---

## Phase 6: Richer learnings (Gap #6)

Current learning prompt only sees diff stats. The real lessons come from *why* things failed — reviewer feedback, build errors, plan concerns.

### Changes

**`capture_task_learning()`** — include failure/feedback context:
```bash
capture_task_learning() {
    local task_id="$1" commit_hash="$2"
    ...
    # Gather richer context
    local task_dir="$SESSION_DIR/tasks/$task_id"
    local extra_context=""
    if [[ -f "$task_dir/audit_feedback.txt" ]]; then
        extra_context="${extra_context}\nAudit feedback: $(head -c 500 "$task_dir/audit_feedback.txt")"
    fi
    if [[ -f "$task_dir/verify_errors.txt" ]]; then
        extra_context="${extra_context}\nVerification errors (before fix): $(head -c 500 "$task_dir/verify_errors.txt")"
    fi
    # Journal entries for this task (rejections, reverts)
    local task_events
    task_events=$(grep "$task_id" "$SESSION_DIR/journal.jsonl" | grep -E 'rejected|revert|hard_block' | tail -3)
    if [[ -n "$task_events" ]]; then
        extra_context="${extra_context}\nPipeline events: $task_events"
    fi

    local learning_prompt="You just completed task $task_id.

Diff summary:
$diff_stat
${extra_context}

Write ONE line (max 120 chars) capturing the most useful technical insight..."
```

### Files modified
- `scripts/nightcrawler.sh`: `capture_task_learning()`

---

## Phase 7: Pre-session codebase orientation (Gap #7)

**New concept:** Before picking the first task, run a lightweight Sonnet call that reads the codebase and produces a `session_context.md` — a summary of conventions, patterns, known issues, and architecture. This gets injected into every subsequent prompt as baseline awareness.

This replaces the current pattern where Sonnet must discover conventions during each planning turn (wasting turns reading files it could have already summarized).

### Changes

**New function `orient_codebase()`:**
```bash
orient_codebase() {
    local context_file="$SESSION_DIR/codebase_context.md"

    local prompt="You are preparing context for an autonomous coding session on a ${PROJECT_DESC} project.

Read the codebase and produce a CONCISE orientation document (max 80 lines) covering:

1. KEY ARCHITECTURE: main entry points, how modules connect, data flow
2. CONVENTIONS: naming patterns, import style, test patterns, error handling
3. KNOWN ISSUES: any TODOs, FIXMEs, or incomplete implementations
4. DEPENDENCY VERSIONS: framework versions, key library versions
5. BUILD/TEST NOTES: anything non-obvious about the build or test setup

MANDATORY READS:
- .claude/CLAUDE.md (project conventions)
- package.json / Cargo.toml / pyproject.toml (deps and scripts)
- src/ directory structure
- test/ directory structure
- Any config files (tsconfig, foundry.toml, etc.)

Be specific. Name files, functions, patterns. This document will be injected into every prompt for the rest of the session — make it count.

Output ONLY the orientation document. No preamble."

    log "Running codebase orientation..."
    local raw_output exit_code
    set +e
    raw_output=$(cd "$PROJECT_PATH" && timeout 120 \
        claude -p "$prompt" \
            --model sonnet \
            --output-format json \
            --max-turns 3 2>/dev/null)
    exit_code=$?
    set -e

    if [[ $exit_code -eq 0 ]]; then
        local content
        content=$(echo "$raw_output" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('result', ''))
except:
    print('')
" 2>/dev/null)

        if [[ -n "$content" && ${#content} -gt 100 ]]; then
            echo "$content" > "$context_file"
            log "Codebase orientation written (${#content} chars)"
            log_claude_cli_cost "$raw_output" "orientation" "orientation"
            return 0
        fi
    fi

    log "Codebase orientation failed or empty — proceeding without"
    return 0  # Non-fatal
}
```

**New function `get_codebase_context()`:**
```bash
get_codebase_context() {
    local context_file="$SESSION_DIR/codebase_context.md"
    [[ -f "$context_file" ]] || return
    local content
    content=$(cat "$context_file" 2>/dev/null)
    [[ -z "$content" ]] && return
    echo "
CODEBASE CONTEXT (from session orientation — use this as baseline knowledge):
$content
"
}
```

**Injection points** — add `$(get_codebase_context)` to:
- `plan_task()` prompt
- `implement_task()` prompt
- `revise_plan()` prompt
- `revise_impl()` prompt

**Call site** — in `main_loop()`, after baseline but before first `pick_next_task`:
```bash
# After baseline health check, before main while loop:
orient_codebase
```

### Cost impact
One extra Sonnet call per session (3 turns max, ~120s). Pays for itself by reducing file-reading turns in every subsequent plan/implement call.

### Files modified
- `scripts/nightcrawler.sh`: new `orient_codebase()`, new `get_codebase_context()`, inject into 4 prompt functions, call in `main_loop()`

---

## Phase 8: Hardcoded "Solidity/Foundry" references (Gap #0 — discovered during audit)

`call_codex.py` has "Solidity/Foundry project" hardcoded in every prompt. This is wrong for Camello (Next.js/TypeScript) and any future project. Should use `PROJECT_DESC` from config.

### Changes

**`nightcrawler.sh`** — pass project description to call_codex.py:
```bash
# In audit_plan_call() and review_impl():
python3 "$SCRIPTS/call_codex.py" audit-plan \
    --plan "$plan_file" \
    --task-file "$task_file" \
    --rules "$STATE_DIR/RULES.md" \
    --project "$PROJECT_PATH" \
    --project-desc "$PROJECT_DESC"
```

**`call_codex.py`** — accept `--project-desc` and use it in prompts:
```python
# Replace all "Solidity/Foundry project" with f"{project_desc} project"
# Default: "software" if not provided
```

### Files modified
- `scripts/call_codex.py`: all prompt strings, argparse
- `scripts/nightcrawler.sh`: `audit_plan_call()`, `review_impl()`

---

## Implementation Order

| Phase | Gap | Risk | Effort | Dependencies |
|-------|-----|------|--------|-------------|
| 1 | Post-commit error feedback | LOW | Small | None |
| 2 | Audit feedback → impl | LOW | Small | None |
| 3 | Full feedback history | LOW | Small | None |
| 8 | Hardcoded Solidity refs | LOW | Small | None |
| 5 | Skip reasons | LOW | Tiny | None |
| 4 | Learnings → Codex | LOW | Medium | None |
| 6 | Richer learnings | LOW | Small | Phase 1, 2 (uses their output files) |
| 7 | Codebase orientation | MEDIUM | Medium | None (but adds 1 prompt/session cost) |

Phases 1-3, 5, 8 are independent — can be implemented in any order or parallel.
Phase 6 depends on Phases 1-2 (reads their output files).
Phase 7 is standalone but highest risk (new prompt, cost increase).

---

## Testing

1. **Syntax check**: `bash -n scripts/nightcrawler.sh` + `python3 -m py_compile scripts/call_codex.py`
2. **Dry run**: `start.sh <project> --budget 1 --dry-run` — exercises plan + audit with new context
3. **Single task**: `--budget 3` on a known-failing task (one that triggers post-commit revert) to verify error feedback flows
4. **Full session**: `--budget 0` overnight, compare task completion rate vs previous sessions

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

## Implementation Order

| Phase | Gap | Risk | Effort | Dependencies |
|-------|-----|------|--------|-------------|
| 1 | Post-commit error feedback | LOW | Small | None |
| 2 | Audit feedback → impl | LOW | Small | None |
| 3 | Full feedback history | LOW | Small | None |
| 8 | Hardcoded Solidity refs | LOW | Small | None |
| 5 | Skip reasons | LOW | Tiny | None |
| 9 | Configurable dev branch | LOW | Small | None |
| 4 | Learnings → Codex | LOW | Medium | None |
| 6 | Richer learnings | LOW | Small | Phase 1, 2 (uses their output files) |
| 7 | Codebase orientation | MEDIUM | Medium | None (but adds 1 prompt/session cost) |

Phases 1-3, 5, 8, 9 are independent — can be implemented in any order or parallel.
Phase 6 depends on Phases 1-2 (reads their output files).
Phase 7 is standalone but highest risk (new prompt, cost increase).

---

## Testing

1. **Syntax check**: `bash -n scripts/nightcrawler.sh` + `python3 -m py_compile scripts/call_codex.py`
2. **Dry run**: `start.sh <project> --budget 1 --dry-run` — exercises plan + audit with new context
3. **Single task**: `--budget 3` on a known-failing task (one that triggers post-commit revert) to verify error feedback flows
4. **Multi-instance**: Run two sessions with different `NC_DEV_BRANCH` values on the same repo — verify no branch collision
5. **Full session**: `--budget 0` overnight, compare task completion rate vs previous sessions

---

## What This Doesn't Change

- Pipeline structure (plan → audit → implement → review → commit → verify)
- Codex as independent reviewer (still separate from Sonnet)
- Budget system, degraded mode, convergence detection
- Session learnings format (still 1-line per task, still async)
- RULES.md / CLAUDE.md injection points
