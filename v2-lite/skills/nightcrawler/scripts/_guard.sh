#!/usr/bin/env bash
# Shared TARGET GUARD for Nightcrawler gate scripts.
#
# The auto-mode allow-list trusts the script PATH, but the target DIRECTORY is still
# attacker-influenceable (a prompt-injected command could pass ANY path). Without this guard a
# "trusted script, hostile path" call — e.g. `codex_review.sh /some/other/repo` (ships that repo's
# diff to OpenAI) or `commit.sh /some/other/repo` (stages/commits unrelated work) — would be
# allowed. This binds the target to the CALLER'S OWN repo and to Nightcrawler-created
# branches/worktrees. Fail CLOSED: on any doubt, reject.
#
# Source this, then call BEFORE any cd/work (it reads the caller's $PWD as the trust anchor):
#   nc_guard <mode> <target>
#     mode = worktree          (write/egress gates: codex_review.sh, prep.sh, commit.sh)
#            repo_or_worktree   (verify.sh — may run on the repo root OR an nc-wt-* worktree)
# Returns 0 = ok, 1 = reject (one-line reason on stderr). The CALLER emits its own infra JSON on
# reject — never proceed past a non-zero return.

_nc_common_dir() { git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null; }

nc_guard() {
  local mode="$1" target="$2"
  local caller_common target_abs target_common branch base
  # caller anchor = the repo the workflow is operating on (its $PWD when the gate script was invoked).
  # The loop runs gate scripts from the repo root (relative worktree paths prove it); the feat cd's
  # to the repo first. If $PWD is somehow not a repo, we reject (fail closed, visible halt).
  caller_common="$(_nc_common_dir "$PWD")" || true
  if [ -z "$caller_common" ]; then
    echo "nc_guard: caller \$PWD is not inside a git repo ($PWD)" >&2; return 1
  fi
  target_abs="$(cd "$target" 2>/dev/null && pwd -P)" || {
    echo "nc_guard: target is not a directory ($target)" >&2; return 1; }
  target_common="$(_nc_common_dir "$target_abs")" || true
  if [ -z "$target_common" ]; then
    echo "nc_guard: target is not inside a git repo ($target_abs)" >&2; return 1
  fi
  if [ "$caller_common" != "$target_common" ]; then
    echo "nc_guard: target repo ($target_common) != caller repo ($caller_common)" >&2; return 1
  fi
  branch="$(git -C "$target_abs" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  base="$(basename "$target_abs")"
  case "$branch" in
    nc/*) ;;
    *) echo "nc_guard: target branch ($branch) is not an nc/* branch" >&2; return 1 ;;
  esac
  if [ "$mode" = worktree ]; then
    case "$base" in
      nc-wt-*) ;;
      *) echo "nc_guard: target ($base) is not an nc-wt-* worktree" >&2; return 1 ;;
    esac
  fi
  return 0
}
