---
name: nightcrawler
description: Run the Nightcrawler closed-loop on one task — discovery, plan, implement, then loop fix↔Codex-review until no P0/P1/P2 findings remain, then verify with type-check + tests. Manual-invoke only via /nightcrawler.
disable-model-invocation: true
---

# Nightcrawler — closed-loop task runner (v2-lite)

This skill is the **playbook**, not the engine. It describes the procedure a human
(or, once G1/G4 pass, a dynamic workflow) executes. The looping/exit logic lives in
the engine; this file holds the *standard that keeps it honest*.

See `NIGHTCRAWLER-V2-SPEC.md` at the repo root for the full design and run-targets.
**Install:** copy this `nightcrawler/` directory into `~/.claude/skills/` (personal) or
`<repo>/.claude/skills/` (project). It's staged here under `v2-lite/` because `.claude/`
is write-protected in the authoring session.

## What this does

Given one task, run a bounded closed loop:

```
discovery → plan → implement → [ Codex review → fix ]*  → verify
                                  ↑ loop while priority<=2 findings, up to ROUND_CAP
```

- **Implementation** is done by Claude (cheap model for bulk work).
- **Review** is done by **Codex** (a different vendor) — this is deliberate, to
  sidestep self-preferential bias. Claude must NOT re-judge Codex's verdict.
- **Verification** is deterministic and **stack-agnostic**: `verify.sh` auto-detects the
  repo's build/test commands (node/python/rust/go/foundry/make) with zero per-project
  config, or honours `NC_VERIFY_CMD` as an explicit override. If nothing is detected it
  fails loud (`no_verifier_detected`) — absence of a verifier is never a pass.

## Severity model (the gate)

Codex returns findings tagged `priority` 0–3. The loop blocks on **priority ≤ 2**.

| Priority | Meaning | Blocks the loop? |
|---|---|---|
| **P0** | Critical: breaks build/tests, data loss, security hole, wrong core logic, regression | Yes |
| **P1** | High: likely bug, missing error handling, broken contract, untested critical path | Yes |
| **P2** | Medium: correctness/maintainability risk, unhandled edge case, logic that will bite | Yes |
| **P3** | Nit: style, naming, cosmetic | No (recorded, never loops) |

**Exit conditions** (whichever comes first):
1. No findings with priority ≤ 2 → loop is clean → proceed to verify.
2. `rounds == ROUND_CAP` → stop, surface remaining P2s to the human. Never loop on a P3.

Defaults: `ROUND_CAP = 3`.

## Hard rules

1. **Bound everything.** Round cap on review/fix; soft token target per task; rely on the
   runtime's enforced 16-concurrent / 1,000-total agent caps as the outer backstop.
   (The `"use Nk tokens"` budget is model-respected, not a runtime kill-switch — do not
   trust it as the guarantee.)
2. **Infra failure ≠ findings.** If Codex fails to run (nonzero exit, empty/unparseable
   output, rate-limit, auth blip), that is `ran:false` — retry with backoff, and NEVER
   feed it into the fix loop as if it were a rejection, and NEVER treat it as clean.
   This is the #1 cause of runaway loops. The adapter enforces this; do not bypass it.
3. **Fresh reviewer each round.** Spawn a new Codex session per review (not `resume`) so it
   re-raises issues it might otherwise decline to repeat.
4. **Thin reviewer.** The reviewer's only job is to run Codex and return JSON. No Claude
   re-judgement of the verdict.
5. **Deterministic ground truth wins.** A clean Codex verdict does not ship code that fails
   `type-check`/`test`. Verification is the final, non-negotiable gate.
6. **Execution model.** The workflow script never runs shell/files. Reviewer and verifier
   *agents* run the commands (`scripts/codex_review.sh`, `scripts/verify.sh`) and return
   strict JSON; the script only evaluates the JSON and branches.

## How the pieces fit

- `review-prompt.md` — the cross-vendor audit persona + severity rubric handed to Codex.
- `sev.schema.json` — the Codex `--output-schema` (findings[] with priority 0–3 + verdict).
- `scripts/codex_review.sh` — reviewer agent runs this → normalized gate JSON.
- `scripts/verify.sh` — verifier agent runs this → `{pass, failures}` JSON.
- `scripts/adapter.py` — normalizes Codex output, enforces the infra guard, maps to/from
  v1's `APPROVED/REJECTED` contract. Pure stdlib; unit-tested in `scripts/test_adapter.py`.

## Status / gates

- v2-lite (this skill + adapter + tests): **buildable now, local-only.**
- The dynamic-workflow JS that drives the loop is **gated on G1 (workflows available on
  the setup) and G4 (Claude CLI on PATH)** — see the spec §11. Until then, the procedure
  above can be run manually, and the scripts/adapter are independently testable.
- Target-B (VPS interactive) tooling is **gated on G3** (subscription-auth-on-server ToS).
