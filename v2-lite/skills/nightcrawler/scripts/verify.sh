#!/usr/bin/env bash
# Verifier agent runs this. Emits {"pass":bool,"failures":[...],"checks":[...]} on stdout.
# Stack-agnostic: verify.py auto-detects the repo's build/test commands (node/python/
# rust/go/foundry/make) with ZERO per-project config, or honours NC_VERIFY_CMD.
# Deterministic ground truth — a clean Codex verdict still must pass this.
#
# Verifies the directory given as the first argument (the worktree), or $PWD if omitted.
# Taking the dir as an arg means the call site needs no leading `cd` — one clean command.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$here/verify.py" "${1:-$PWD}"
