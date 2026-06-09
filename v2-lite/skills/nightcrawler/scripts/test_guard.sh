#!/usr/bin/env bash
# Tests for _guard.sh nc_guard (auto-mode target guard). Builds temp repos + an nc-wt worktree and
# checks the accept/reject matrix. Run:  bash test_guard.sh
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/_guard.sh"

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; pass=$((pass + 1)); else echo "FAIL $1 (expected $2 got $3)"; fail=$((fail + 1)); fi; }
gitq() { git -c init.defaultBranch=main -c user.email=a@b.c -c user.name=x "$@"; }
# Run nc_guard from a given caller dir; echo only its exit code.
run() { ( cd "$1" && shift && nc_guard "$@" 2>/dev/null; echo $? ); }

ROOT="$(mktemp -d)"
R="$ROOT/repo"; mkdir -p "$R"
( cd "$R" && gitq init -q && echo hi > f && gitq add -A && gitq commit -qm init && gitq checkout -q -b nc/feat-x )
( cd "$R" && gitq worktree add -q -b nc/feat/x/t "$ROOT/nc-wt-task" >/dev/null 2>&1 )
WT="$ROOT/nc-wt-task"
# A DIFFERENT repo that also looks nc-ish (nc/ branch + nc-wt-ish name) — the same-repo check must still reject it.
O="$ROOT/other-nc-wt-task"; mkdir -p "$O"
( cd "$O" && gitq init -q && echo hi > f && gitq add -A && gitq commit -qm init && gitq checkout -q -b nc/feat-y )

# accepts
check "verify accepts repo-root on nc-branch"      0 "$(run "$R" repo_or_worktree "$R")"
check "verify accepts nc-wt worktree"              0 "$(run "$R" repo_or_worktree "$WT")"
check "worktree-mode accepts nc-wt worktree"       0 "$(run "$R" worktree "$WT")"
# rejects
check "worktree-mode rejects repo root (not nc-wt-*)" 1 "$(run "$R" worktree "$R")"
check "rejects different repo (worktree mode)"     1 "$(run "$R" worktree "$O")"
check "rejects different repo (verify mode)"       1 "$(run "$R" repo_or_worktree "$O")"
check "rejects non-git target"                     1 "$(run "$R" repo_or_worktree "$ROOT")"
check "rejects caller not in a git repo"           1 "$(run "$ROOT" repo_or_worktree "$R")"
# non-nc branch
( cd "$R" && gitq checkout -q main )
check "rejects target on non-nc branch"            1 "$(run "$R" repo_or_worktree "$R")"
( cd "$R" && gitq checkout -q nc/feat-x )

rm -rf "$ROOT"
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
