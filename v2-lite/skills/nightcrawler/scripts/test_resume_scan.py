"""Contract tests for resume_scan.py (auto-resume scanner).

    python3 test_resume_scan.py      # stdlib runner (bottom)
    python3 -m pytest -q

No real ~/.nightcrawler is touched — every test writes feat-state files into a temp dir.
"""
import json
import os
import sys
import tempfile

import resume_scan as R


def _feats_dir(files):
    """Create a temp feats dir; `files` maps filename -> raw file contents (string)."""
    d = tempfile.mkdtemp(prefix="nc_resume_")
    for name, contents in files.items():
        with open(os.path.join(d, name), "w", encoding="utf-8") as fh:
            fh.write(contents)
    return d


def _state(status, *, feat="My Feat", feat_id="my-feat-abc123",
           tasks=(("do a", "a-1"), ("do b", "b-2")), base="main"):
    """Build a minimal feat-state JSON string like nightcrawler-feat persists."""
    return json.dumps({
        "featId": feat_id,
        "feat": feat,
        "featBranch": "nc/feat-" + feat_id,
        "base": base,
        "tasks": [{"taskId": tid, "spec": spec, "status": "pending"} for spec, tid in tasks],
        "status": status,
    })


# --- a running feat is returned -------------------------------------------

def test_running_feat_is_resumable():
    d = _feats_dir({"f.json": _state("running")})
    out = R.scan(d)
    assert len(out) == 1
    assert out[0]["featId"] == "my-feat-abc123"
    assert out[0]["feat"] == "My Feat"
    assert out[0]["tasks"] == ["do a", "do b"]   # SPEC strings, ready to feed back as args.tasks
    assert out[0]["base"] == "main"


def test_running_feat_carries_title_for_arg_reconstruction():
    # The title is the load-bearing field — featId is a one-way hash, so resume needs `feat`.
    d = _feats_dir({"f.json": _state("running", feat="Ship the widget")})
    assert R.scan(d)[0]["feat"] == "Ship the widget"


# --- every terminal status is excluded ------------------------------------

def test_each_terminal_status_excluded():
    for status in R.TERMINAL_STATUSES:
        d = _feats_dir({"f.json": _state(status)})
        assert R.scan(d) == [], "expected %s to be NON-resumable" % status


def test_done_not_resumable():
    d = _feats_dir({"f.json": _state("done")})
    assert R.scan(d) == []


def test_needs_human_not_resumable():
    # needs_human is a deliberate pause — resuming requires an answers map, never a blind re-invoke.
    d = _feats_dir({"f.json": _state("needs_human")})
    assert R.scan(d) == []


def test_unknown_status_not_resumable():
    # Defensive: only the exact "running" string is safe; any other value is excluded.
    d = _feats_dir({"f.json": _state("paused_somehow")})
    assert R.scan(d) == []


# --- malformed / empty files are skipped ----------------------------------

def test_empty_file_skipped():
    d = _feats_dir({"f.json": ""})
    assert R.scan(d) == []


def test_malformed_json_skipped():
    d = _feats_dir({"f.json": "{ not valid json"})
    assert R.scan(d) == []


def test_non_object_json_skipped():
    d = _feats_dir({"f.json": "[1, 2, 3]"})
    assert R.scan(d) == []


def test_running_but_missing_title_skipped():
    obj = json.loads(_state("running"))
    del obj["feat"]
    d = _feats_dir({"f.json": json.dumps(obj)})
    assert R.scan(d) == []


def test_running_but_no_task_specs_skipped():
    d = _feats_dir({"f.json": _state("running", tasks=())})
    assert R.scan(d) == []


def test_non_json_files_ignored():
    d = _feats_dir({"f.json": _state("running"), "notes.txt": "ignore me", "x.json.bak": "junk"})
    assert len(R.scan(d)) == 1


def test_missing_dir_returns_empty():
    assert R.scan("/nonexistent/nc/feats/dir") == []


# --- mixed corpus: only running feats survive -----------------------------

def test_mixed_corpus_returns_only_running():
    d = _feats_dir({
        "run1.json": _state("running", feat_id="run1"),
        "done1.json": _state("done", feat_id="done1"),
        "halt1.json": _state("halted", feat_id="halt1"),
        "run2.json": _state("running", feat_id="run2"),
        "bad1.json": "{bad",
    })
    ids = sorted(e["featId"] for e in R.scan(d))
    assert ids == ["run1", "run2"]


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
