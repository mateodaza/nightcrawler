# Nightcrawler v2-lite scaffold

The durable, local-only half of Nightcrawler v2 (see `../NIGHTCRAWLER-V2-SPEC.md`).
Everything here is buildable and testable without dynamic workflows or a VPS — it's the
*standard that keeps it honest*, not the engine.

## Layout

```
v2-lite/
  skills/nightcrawler/
    SKILL.md            # the playbook: phases, rules, P0/P1/P2 model, hard rules
    review-prompt.md    # cross-vendor audit persona + severity rubric for Codex
    sev.schema.json     # Codex --output-schema (findings[] priority 0–3 + verdict)
    scripts/
      adapter.py        # normalize Codex output, infra-vs-findings guard, v1 back-compat
      test_adapter.py   # contract tests (pure stdlib + pytest)
      codex_review.sh   # reviewer agent → normalized gate JSON
      verify.sh         # verifier agent → {pass, failures} JSON
```

## Install the skill (when ready)

`.claude/` is write-protected in the authoring session, so the skill + workflow are staged
here and installed with one command (copy, not symlink — the gate must be frozen between
deliberate installs, see spec §12):

```bash
./install.sh            # copies skill + workflow into ~/.claude, prints freeze-check shasums
./install.sh --check    # before any auto/feat run: exit 0 = in sync, exit 1 = drifted/stale
./install.sh --auto-setup   # OPT-IN: trust the Codex review egress so AUTO mode runs unattended
./install.sh --env-check ~/path/to/repo   # preflight: is the repo runnable (node ver / deps / toolchain)?
```

Run `--env-check <repo>` before a feat/auto run so verify never false-fails on a setup issue
(missing `node_modules`, wrong node). The loop also self-protects: a toolchain that can't run
returns `verify_inconclusive` (not `verify_failed`) — a missing env never masquerades as broken
code. And a cheap classify pass routes the think-model by task complexity (trivial→Sonnet,
standard/complex→Opus) so small tasks don't pay Opus latency.

Re-run `./install.sh` after editing anything under `v2-lite/`, and `--check` if you're unsure
whether the installed gate matches source. This is the fix for the source↔installed drift.

### Unattended auto mode (`--auto-setup`)

Under auto mode the classifier blocks the Codex review by default (it sends the diff to
OpenAI = "external"). `--auto-setup` adds one natural-language trust line to
`autoMode.environment` in `~/.claude/settings.json` so that one egress is trusted — the loop
then runs unattended with no per-run approval, while the classifier still guards everything
else. It is **opt-in** (not part of plain install), does a **structured JSON merge that
preserves every existing setting**, **backs up** the file first, keeps **`"$defaults"`** so
built-in classifier protections stay intact, and is idempotent. Verify with
`claude auto-mode config`. To undo, delete the line (or restore the `.nc-bak.*` backup).

## Run the tests

```bash
cd v2-lite/skills/nightcrawler/scripts
python3 test_adapter.py        # stdlib runner — NO dependencies
# python3 -m pytest -q         # also works if you have pytest (dev-only, optional)
```

No network, no Codex, no Claude, no pytest needed — these are pure stdlib contract
tests for the gate logic.

## What's gated (do NOT build yet)

- **Workflow JS** (the loop engine) — gated on **G1** (dynamic workflows available on your
  setup, v2.1.154+) and **G4** (`claude` on PATH).
- **Target-B tooling** (VPS interactive) — gated on **G3** (subscription-auth-on-server ToS).

See spec §11 for the full gate list. v2-lite stands alone until those clear.

## Smoke-test the live pieces (needs `codex` + a JS repo; optional)

```bash
chmod +x skills/nightcrawler/scripts/*.sh
# from inside a repo with a working-tree diff:
/path/to/skills/nightcrawler/scripts/codex_review.sh    # -> normalized gate JSON
/path/to/skills/nightcrawler/scripts/verify.sh          # -> {pass, failures}
```
