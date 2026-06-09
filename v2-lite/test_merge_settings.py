"""Contract tests for merge_settings.py (auto-mode trust merger).

    python3 test_merge_settings.py      # stdlib runner (bottom)
    python3 -m pytest -q                # also works

Covers: fresh creation carries $defaults; existing keys preserved; existing env appended
without disturbing the user's $defaults choice; idempotency; malformed-input refusal;
and the CLI --apply/--check round-trip against a temp settings file.
"""
import copy
import json
import os
import subprocess
import sys
import tempfile

import merge_settings as M


# --- pure merge logic ------------------------------------------------------

def test_fresh_creates_env_with_defaults_then_trust():
    out = M.apply({})
    assert out["autoMode"]["environment"] == [M.DEFAULTS, M.TRUST_LINE]


def test_preserves_all_other_settings():
    src = {"permissions": {"allow": ["Bash(npm test)"]}, "defaultMode": "plan"}
    out = M.apply(copy.deepcopy(src))
    assert out["permissions"] == src["permissions"]
    assert out["defaultMode"] == "plan"
    assert M.has_trust_line(out)


def test_existing_env_appends_and_keeps_user_defaults_choice():
    src = {"autoMode": {"environment": [M.DEFAULTS, "Trusted: github.com/acme"]}}
    out = M.apply(copy.deepcopy(src))
    env = out["autoMode"]["environment"]
    assert env[0] == M.DEFAULTS
    assert "Trusted: github.com/acme" in env
    assert env[-1] == M.TRUST_LINE


def test_existing_env_without_defaults_is_left_without_defaults():
    # user deliberately took full ownership (no $defaults) — don't re-add it, just append
    src = {"autoMode": {"environment": ["Only my custom rule"]}}
    out = M.apply(copy.deepcopy(src))
    env = out["autoMode"]["environment"]
    assert M.DEFAULTS not in env
    assert env == ["Only my custom rule", M.TRUST_LINE]


def test_idempotent():
    once = M.apply({})
    twice = M.apply(copy.deepcopy(once))
    assert twice["autoMode"]["environment"].count(M.TRUST_LINE) == 1


def test_malformed_env_raises():
    try:
        M.apply({"autoMode": {"environment": "not-a-list"}})
        assert False, "expected ValueError"
    except ValueError:
        pass


def test_has_trust_line():
    assert M.has_trust_line({"autoMode": {"environment": [M.DEFAULTS, M.TRUST_LINE]}}) is True
    assert M.has_trust_line({"autoMode": {"environment": [M.DEFAULTS]}}) is False
    assert M.has_trust_line({}) is False


# --- CLI round-trip --------------------------------------------------------

def _tmp(contents=None):
    d = tempfile.mkdtemp(prefix="nc_settings_")
    p = os.path.join(d, "settings.json")
    if contents is not None:
        with open(p, "w") as fh:
            fh.write(contents)
    return p


def _run(args):
    return subprocess.run([sys.executable, M.__file__] + args,
                          capture_output=True, text=True)


def test_cli_apply_then_check_roundtrip():
    p = _tmp(json.dumps({"defaultMode": "plan"}))
    r1 = _run(["--apply", "--settings", p])
    assert r1.returncode == 0
    data = json.load(open(p))
    assert data["defaultMode"] == "plan"           # preserved
    assert M.has_trust_line(data)                   # added
    assert os.path.exists(p)
    # backup was made
    bak = [f for f in os.listdir(os.path.dirname(p)) if ".nc-bak." in f]
    assert bak, "expected a backup file"
    # check passes now
    assert _run(["--check", "--settings", p]).returncode == 0
    # second apply is a no-op
    r2 = _run(["--apply", "--settings", p])
    assert "no change" in r2.stdout


def test_cli_check_missing_is_exit_1():
    p = _tmp(json.dumps({}))
    assert _run(["--check", "--settings", p]).returncode == 1


def test_cli_refuses_invalid_json():
    p = _tmp("{not valid json")
    r = _run(["--apply", "--settings", p])
    assert r.returncode == 2 and "refusing" in (r.stderr + r.stdout).lower()
    # file left untouched
    assert open(p).read() == "{not valid json"


# --- stdlib runner ---------------------------------------------------------

if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items())
             if k.startswith("test_") and callable(v)]
    failed = 0
    for fn in tests:
        try:
            fn()
            print("ok   " + fn.__name__)
        except AssertionError as exc:
            failed += 1
            print("FAIL " + fn.__name__ + ": " + str(exc))
        except Exception as exc:  # noqa: BLE001
            failed += 1
            print("ERR  " + fn.__name__ + ": " + repr(exc))
    print("\n%d passed, %d failed" % (len(tests) - failed, failed))
    sys.exit(1 if failed else 0)
