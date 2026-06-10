# Camus

**An autonomous coding loop that can't grade its own homework.**

Camus runs one task — or an ordered feature's worth of tasks — through a closed loop:
plan → implement → cross-vendor review → fix → deterministic verify. Claude writes the
code; **Codex (a different vendor) reviews it**; `verify.sh` runs the repo's own
type-check and tests. Nothing ships on self-assessment.

Formerly Nightcrawler v2. The v1 bash orchestrator lives at the repo root as
portfolio/OSS; Camus is its judgment layer ported onto Claude Code dynamic workflows.
Full design: [`../CAMUS-SPEC.md`](../CAMUS-SPEC.md).

```
discovery → plan → implement → [ Codex review ↔ fix ]* → commit gate → dep-prep → verify
                                 ↑ loops while P0/P1/P2 findings remain, ROUND_CAP = 3
```

## Why it's honest

- **Cross-vendor gate.** The reviewer is Codex, not another Claude. Claude never
  re-judges the verdict; a thin runner relays Codex's JSON verbatim. Every round is
  persisted to `~/.camus/reviews/` — a missing audit file means the binary never ran.
- **Deterministic ground truth.** A clean review does not ship code that fails
  `type-check`/`test`. Stack-agnostic verifier (node/python/rust/go/foundry/make),
  `CAMUS_VERIFY_CMD` override, fails loud when nothing is detected.
- **Infra failure ≠ findings.** Codex not running is `ran:false` — retried, never fed
  into the fix loop, never treated as clean. Missing `node_modules` is
  `verify_inconclusive`, never `verify_failed`. A broken environment can't masquerade
  as broken (or working) code.
- **Work provably lands.** A commit gate after review-clean: no staged changes →
  `no_changes`, never a silent empty merge. `done` carries the `commit_sha`.

## Autonomy with a leash

- **Zero-click auto mode** — `install.sh --auto-setup` installs a narrow scoped profile:
  one egress trust line (the Codex review diff) plus allow rules for the five gate
  scripts, nothing else. Every gate script is bound by `_guard.sh` to the caller's repo,
  `camus/*` branches, and `camus-wt-*` worktrees — fail-closed, hardened across three
  Codex review rounds.
- **HITL policy dial** — `autonomous` | `ask_on_ambiguity` (default) | `ask_on_major`.
  Genuinely ambiguous tasks halt with a question (`needs_human`); resume threads your
  answer back in. Either way, an always-on **decisions log** puts every judgment call
  ("widened param type `string` → `unknown`, because…") in the report.
- **Model control** — a cheap classify pass routes the think-model (trivial→Sonnet,
  else Opus); `model`/`modelTier` force it; persistent review findings escalate the fix
  model automatically (round ≥ 2 or any P0). Bounded everything: round caps, agent caps.
- **Auto-resume** — interrupted feats are detected (`running`, idle ≥ 30 min) and resumed
  with their canonical args, not a lookalike reconstruction.

## Layout

```
camus/
  install.sh              # install/--check/--auto-setup/--env-check
  merge_settings.py       # narrow auto-profile merger (preserves all existing settings)
  workflows/
    camus-loop.workflow.js   # one task: the closed loop
    camus-feat.workflow.js   # M1 feat runner: sequential tasks, baseline + integration verify
  skills/camus/
    SKILL.md              # the playbook: severity model, hard rules, run surface
    review-prompt.md      # cross-vendor audit persona + completeness check
    sev.schema.json       # Codex --output-schema
    scripts/              # gate scripts + guard + adapter + preflight, all unit-tested
```

## Install & run

```bash
./install.sh                 # copy skill + workflows into ~/.claude (copy, not symlink — frozen gate)
./install.sh --check         # preflight: exit 0 = in sync, 1 = drifted (run before any auto/feat run)
./install.sh --env-check <repo>   # is the repo runnable? (node version, deps, toolchain)
./install.sh --auto-setup    # opt-in: scoped unattended profile + per-run recipe
```

Per-run (from the target repo):

```bash
export CAMUS_REPO_ROOT="$(pwd -P)"
export CAMUS_VERIFY_CMD="pnpm type-check && pnpm test"   # include TESTS, not just types
claude --permission-mode auto
# then: /camus-feat with your task list, or /camus-loop <one task>
```

## Tests

Pure stdlib, no network, no deps:

```bash
cd skills/camus/scripts
for t in test_adapter.py test_verify.py test_env_check.py test_prep.py \
         test_resume_scan.py test_review_audit.py; do python3 $t; done
bash test_guard.sh
cd ../../.. && python3 test_merge_settings.py && node test_hitl_workflows.js
```

159 assertions across 9 suites. The cross-vendor gate reviewed its own adapter,
guard, and workflows — and caught real bugs each time.

## Hard boundary

Trusted-code tool only. The verifier runs the repo's own build/test commands — that is
RCE by design on code you already trust. Do not point it at untrusted repos, and never
run it as root. Camus may improve itself only through explicit maintenance tasks that
pass its own gates; it never mutates its runner, skill, verifier, schemas, or
permissions during a feat run.
