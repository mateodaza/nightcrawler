#!/usr/bin/env python3
"""Idempotently add the Nightcrawler review-egress trust line to ~/.claude/settings.json
so the loop's cross-vendor Codex review runs under AUTO mode without per-run approval.

The classifier blocks the review by default because it sends the working-tree diff to
OpenAI (an "external" destination = potential exfiltration). Listing that egress in
autoMode.environment redefines it as trusted for this purpose only — everything else the
loop does still goes through the classifier.

Usage:
  merge_settings.py --apply [--settings PATH]   # add the line (backs up first), idempotent
  merge_settings.py --check [--settings PATH]   # exit 0 if present, 1 if missing

Safety:
- Structured JSON merge — every existing setting is preserved; only autoMode.environment is touched.
- A freshly-created environment array always includes "$defaults" (omitting it would discard
  the built-in classifier protections — see the auto-mode-config docs' Danger note). An
  existing array's "$defaults" choice is left exactly as the user set it.
- Backs up the file before writing; refuses to touch invalid JSON.
"""
import argparse
import json
import os
import shutil
import sys
import time

TRUST_LINE = (
    "Code review: the local `codex` CLI sends working-tree diffs to OpenAI for an intended, "
    "trusted cross-vendor review (the Nightcrawler review gate). OpenAI is a trusted destination "
    "for this diff-review purpose only."
)
DEFAULTS = "$defaults"


def default_settings_path():
    return os.path.join(os.path.expanduser("~"), ".claude", "settings.json")


def load(path):
    """Return (settings_dict, existed). Raises ValueError on invalid JSON."""
    if not os.path.exists(path):
        return {}, False
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    if not text.strip():
        return {}, False
    data = json.loads(text)  # ValueError propagates -> caller refuses to touch
    if not isinstance(data, dict):
        raise ValueError("settings root is not a JSON object")
    return data, True


def has_trust_line(settings):
    env = (settings.get("autoMode") or {}).get("environment")
    return isinstance(env, list) and TRUST_LINE in env


def apply(settings):
    """Add the trust line, preserving everything else. Idempotent."""
    am = settings.setdefault("autoMode", {})
    if not isinstance(am, dict):
        raise ValueError("autoMode is not an object")
    env = am.get("environment")
    if env is None:
        env = [DEFAULTS]                 # fresh array MUST carry $defaults
    elif not isinstance(env, list):
        raise ValueError("autoMode.environment is not an array")
    if TRUST_LINE not in env:
        env.append(TRUST_LINE)
    am["environment"] = env
    return settings


def main(argv=None):
    ap = argparse.ArgumentParser(description="Nightcrawler auto-mode trust merger")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--settings", default=default_settings_path())
    args = ap.parse_args(argv)
    path = args.settings

    try:
        settings, existed = load(path)
    except (ValueError, TypeError) as exc:
        print("ERROR: %s is not valid JSON (%s) — refusing to touch it." % (path, exc),
              file=sys.stderr)
        return 2

    if args.check:
        if has_trust_line(settings):
            print("ok:    auto-mode review-egress trust present")
            return 0
        print("info:  auto-mode review-egress trust MISSING "
              "(optional — run `install.sh --auto-setup` for unattended auto runs)")
        return 1

    if args.apply:
        if has_trust_line(settings):
            print("auto-mode trust already present — no change.")
            return 0
        try:
            apply(settings)
        except ValueError as exc:
            print("ERROR: %s — refusing to modify settings." % exc, file=sys.stderr)
            return 2
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if existed:
            backup = "%s.nc-bak.%d" % (path, int(time.time()))
            shutil.copy2(path, backup)
            print("backed up existing settings -> %s" % backup)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(settings, fh, indent=2)
            fh.write("\n")
        print("added auto-mode review-egress trust to %s (\"$defaults\" preserved)." % path)
        print("verify with: claude auto-mode config")
        return 0

    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
