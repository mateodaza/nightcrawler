#!/usr/bin/env python3
"""Preflight environment doctor for the Nightcrawler loop.

Confirms a repo is actually RUNNABLE before the loop trusts its verifier — so the loop never
reports a code failure when the real problem is "deps not installed" or "wrong node" (the
run-1 false negative: `turbo` not found / node v12 in a fresh worktree).

Run at feat baseline / first call / install:
  env_check.py [REPO]        # exit 0 = ready, 1 = not ready (prints what to fix)

Checks: required-vs-actual node version, node deps installed, and that every verifier toolchain
binary resolves on PATH. Reuses verify.detect_checks so it checks exactly what the verifier runs.
"""
import json
import os
import re
import shutil
import subprocess
import sys

import verify  # same dir; checks the exact commands the verifier will run


def required_node(repo):
    for fn in (".node-version", ".nvmrc"):
        p = os.path.join(repo, fn)
        if os.path.exists(p):
            v = open(p, encoding="utf-8").read().strip()
            if v:
                return v
    pkg = os.path.join(repo, "package.json")
    if os.path.exists(pkg):
        try:
            eng = (json.load(open(pkg, encoding="utf-8")) or {}).get("engines", {})
            if isinstance(eng, dict) and eng.get("node"):
                return str(eng["node"])
        except Exception:
            pass
    return None


def _major(v):
    m = re.search(r"(\d+)", v or "")
    return m.group(1) if m else None


def _detect_node_version(which):
    if which("node") is None:
        return None
    try:
        return subprocess.run(["node", "--version"], capture_output=True,
                              text=True).stdout.strip()
    except Exception:
        return None


def check_env(repo, which=None, node_version=None, env=None):
    """Return a list of issue strings (empty = ready).
    `which`, `node_version`, `env` are injectable for tests."""
    which = which or shutil.which
    env = env if env is not None else os.environ

    issues = []

    # node version (only if the repo declares one)
    req = required_node(repo)
    if req is not None:
        actual = node_version() if node_version else _detect_node_version(which)
        rmaj, amaj = _major(req), _major(actual)
        if actual is None:
            issues.append("node not found on PATH (repo expects node %s)" % req)
        elif rmaj and amaj and rmaj != amaj:
            issues.append("node major mismatch: repo wants %s, found %s "
                          "(switch with nvm/fnm before running)" % (req, actual))

    # node deps installed
    if os.path.exists(os.path.join(repo, "package.json")):
        has_lock = any(os.path.exists(os.path.join(repo, f)) for f in
                       ("pnpm-lock.yaml", "yarn.lock", "package-lock.json", "bun.lockb"))
        if has_lock and not os.path.isdir(os.path.join(repo, "node_modules")):
            issues.append("node_modules missing — run the project's install "
                          "(e.g. `pnpm install`) before verify can run")

    # verifier toolchain resolvable
    for chk in verify.detect_checks(repo, env):
        binary = chk["cmd"][0]
        if binary == "bash":            # NC_VERIFY_CMD override runs via `bash -lc`; bash always present
            continue
        if which(binary) is None:
            issues.append("`%s` not on PATH (needed for verify step '%s')" % (binary, chk["name"]))

    return issues


def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    repo = argv[0] if argv else os.getcwd()
    issues = check_env(repo)
    if not issues:
        print("ok: environment ready (node version, deps, and verifier toolchain present).")
        return 0
    print("NOT READY — fix these before running the loop (otherwise verify is inconclusive):")
    for i in issues:
        print("  - " + i)
    return 1


if __name__ == "__main__":
    sys.exit(main())
