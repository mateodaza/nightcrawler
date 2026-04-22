#!/usr/bin/env bash
# tier_stance.sh — F6b.2a: render per-tier stance blocks for prompt headers.
#
# The orchestrator (nightcrawler.sh) derives a complexity tier via
# complexity_tier.py, then sources this file to render a markdown stance
# block once per task. The block is written to $SESSION_DIR/tasks/<id>/
# tier_stance.md and injected into the planner + plan-revisor prompts, and
# passed via --tier-stance-file to call_codex.py for auditor + reviewer use.
#
# Wording is deliberately concrete: what to *do* differently by tier, not
# just "this is risky". The auditor/reviewer additionally sees a line that
# the orchestrator's tier is authoritative for stance; disagreement goes
# into the structured output's complexity_tier field as calibration and is
# journaled as a tier_mismatch, but does not override the stance above.
#
# No loop-cap changes here — F6b.2a is stance-only. Caps land in F6b.2b
# after one observation batch with stance headers alone.
#
# Source from nightcrawler.sh:
#     source "$SCRIPTS/lib/tier_stance.sh"
# Then call:
#     render_tier_stance_block TIER SIGNALS_JSON OUT_PATH

set -u

# -----------------------------------------------------------------------------
# Stance bodies (per tier). Kept short on purpose — the LLM already has a long
# system prompt; additional header noise costs attention. Each block ends with
# a sentence reminding the auditor/reviewer that the tier is authoritative.
# -----------------------------------------------------------------------------

_tier_stance_body_TRIVIAL() {
    cat <<'EOF'
**Stance (authoritative):** This task is small-surface. Plan tightly. A one-line
edit plus a matching single test is a complete plan — do NOT invent scaffolding,
helpers, or refactors the task does not ask for. Acceptance criteria cap the
scope; anything beyond them is out of scope.

For auditor/reviewer: do not require multi-surface test coverage here. A minimal
test proving the acceptance criterion is sufficient. Reject only for real
correctness issues, not for "could be more thorough".
EOF
}

_tier_stance_body_STANDARD() {
    cat <<'EOF'
**Stance (authoritative):** Default posture. Plan and implement thoroughly:
cover happy path plus the obvious error/edge cases from the acceptance criteria,
follow the conventions in .claude/CLAUDE.md, prefer existing helpers over new
ones. Don't expand scope beyond the acceptance criteria, but don't strip tests
down to the bare minimum either.
EOF
}

_tier_stance_body_RISKY() {
    cat <<'EOF'
**Stance (authoritative):** Multi-surface and/or security-sensitive. Enumerate
every surface the task touches (schema, migration, API handler, auth/tenant
scoping, UI, tests) and give each one its own plan section. Do not summarize or
flatten surfaces — be exhaustive per surface so the reviewer can walk them one
by one.

Every security-relevant surface must have an explicit test assertion: tenant
scoping, authorization, cross-tenant access rejection, destructive-action
confirmation paths. "Behavior covered by existing tests" is not acceptable for
auth or migration code — write the case.

For auditor/reviewer: hold the plan and the implementation to this bar. If a
surface lacks a test, that is a blocking issue, not an advisory.
EOF
}

_tier_stance_body_UNKNOWN() {
    cat <<'EOF'
**Stance:** The orchestrator did not derive a tier for this task (classifier
unavailable or task body empty). Proceed with STANDARD-tier posture: thorough
but not exhaustive, no RISKY-tier enumerations required.
EOF
}

# -----------------------------------------------------------------------------
# render_tier_stance_block TIER SIGNALS_JSON OUT_PATH
#
# TIER          — "TRIVIAL" | "STANDARD" | "RISKY" | ""/"UNKNOWN"
# SIGNALS_JSON  — raw JSON string from complexity_tier.py (single line,
#                 e.g. '{"ac_count":3,"listed_files":2,"keywords":["auth"],
#                 "keywords_raw":["auth","schema"],"branch":"solo_kw_demote"}')
# OUT_PATH      — file to write the rendered markdown block to
#
# Writes a self-contained markdown block that can be prepended to a prompt.
# The block names the tier, echoes the signals verbatim (so the LLM can see
# what specifically triggered it), and states the per-tier stance plus the
# authority/calibration rule for the auditor/reviewer.
# -----------------------------------------------------------------------------
render_tier_stance_block() {
    local tier="${1:-UNKNOWN}"
    local signals_json="${2:-{\}}"
    local out_path="${3:?render_tier_stance_block: OUT_PATH required}"

    # Normalize empty/garbled tier inputs so the case below always matches.
    case "$tier" in
        TRIVIAL|STANDARD|RISKY) : ;;
        *) tier="UNKNOWN" ;;
    esac

    local stance_body
    stance_body=$("_tier_stance_body_${tier}")

    # The calibration line is only useful for the auditor + reviewer (Codex),
    # but leaving it in the planner's header is harmless and removes a
    # branch. The orchestrator is still the one that journals tier_mismatch.
    local calibration_line
    if [[ "$tier" == "UNKNOWN" ]]; then
        calibration_line=""
    else
        calibration_line=$'\n\n**Calibration note for auditor/reviewer:** The orchestrator\'s tier is authoritative for stance. If you believe this tier is miscalibrated, report it via the `complexity_tier` field in your structured output — the mismatch will be journaled as telemetry but will NOT change the stance above.'
    fi

    mkdir -p "$(dirname "$out_path")"
    cat > "$out_path" <<EOF
## Orchestrator-derived complexity tier: ${tier}

**Deterministic signals:** \`${signals_json}\`

${stance_body}${calibration_line}
EOF
}

# -----------------------------------------------------------------------------
# read_tier_stance OUT_PATH
# Convenience: print the stance block to stdout if it exists, else nothing.
# Used by planner prompts that want to inline the file via command substitution.
# -----------------------------------------------------------------------------
read_tier_stance() {
    local path="${1:-}"
    [[ -n "$path" && -f "$path" ]] || return 0
    cat "$path"
}
