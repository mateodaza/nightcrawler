#!/usr/bin/env bash
# Worktree dep-prep: ensure a fresh worktree has its deps before verify (Node only; no-op otherwise).
# Emits {"prepped":bool,"ran":[...]|null,...} on stdout. exit 0 = prepped/no-op, 1 = install failed.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# Target guard (auto-mode hardening): only prep deps inside an nc-wt-* worktree of the caller's repo.
source "$here/_guard.sh"
if ! nc_guard worktree "${1:-$PWD}"; then
  printf '{"prepped": false, "ran": null, "reason": "guard_refused", "log_tail": "target rejected by nc_guard (not a same-repo nc-wt-* worktree)"}\n'
  exit 0
fi
exec python3 "$here/prep.py" "${1:-$PWD}"
