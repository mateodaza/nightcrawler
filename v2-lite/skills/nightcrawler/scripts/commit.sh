#!/usr/bin/env bash
# Commit gate: stage + commit the worktree's reviewed change so the branch HEAD actually
# CONTAINS the verified work — otherwise the feat-runner's merge ships nothing (run-2 bug).
# Emits {"committed":bool,"sha":...}. No staged changes -> committed:false -> the loop returns
# no_changes (never a false "done"). Runs AFTER Codex review (which reads the uncommitted diff).
set -uo pipefail
dir="${1:?worktree dir required}"
msg="${2:-nc: task}"
if ! cd "$dir" 2>/dev/null; then
  printf '{"committed": false, "error": "bad worktree dir"}\n'
  exit 0
fi
git add -A
if git diff --cached --quiet; then
  printf '{"committed": false}\n'
else
  if git commit -q -m "$msg"; then
    printf '{"committed": true, "sha": "%s"}\n' "$(git rev-parse --short HEAD)"
  else
    printf '{"committed": false, "error": "git commit failed"}\n'
  fi
fi
