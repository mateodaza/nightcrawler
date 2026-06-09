#!/usr/bin/env bash
# Worktree dep-prep: ensure a fresh worktree has its deps before verify (Node only; no-op otherwise).
# Emits {"prepped":bool,"ran":[...]|null,...} on stdout. exit 0 = prepped/no-op, 1 = install failed.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$here/prep.py" "${1:-$PWD}"
