#!/usr/bin/env python3
"""Dual wall-clock + idle-output timeout runner.

Runs a command with two independent timeout conditions:
  - Wall-clock timeout: total elapsed time since start
  - Idle timeout: time since last output on stdout/stderr

Merges stderr into stdout (single stream). Streams output in real-time.
Kills the entire process group on timeout.

Exit codes:
  124 = wall-clock timeout
  125 = idle timeout
  other = command's own exit code

Usage: run_with_timeout.py <wall_seconds> <idle_seconds> <command...>
"""

import os
import selectors
import signal
import subprocess
import sys
import time


def kill_group(proc):
    """Kill the entire process group (SIGTERM then SIGKILL)."""
    try:
        pgid = os.getpgid(proc.pid)
        os.killpg(pgid, signal.SIGTERM)
        time.sleep(2)
        try:
            os.killpg(pgid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    except (ProcessLookupError, PermissionError):
        pass


def main():
    if len(sys.argv) < 4:
        print("Usage: run_with_timeout.py <wall_seconds> <idle_seconds> <command...>",
              file=sys.stderr)
        sys.exit(1)

    wall = int(sys.argv[1])
    idle = int(sys.argv[2])
    cmd = sys.argv[3:]

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        preexec_fn=os.setpgrp,
    )

    start = time.time()
    last_out = time.time()

    sel = selectors.DefaultSelector()
    sel.register(proc.stdout, selectors.EVENT_READ)

    while proc.poll() is None:
        events = sel.select(timeout=1.0)
        for key, _ in events:
            chunk = os.read(key.fileobj.fileno(), 8192)
            if chunk:
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
                last_out = time.time()

        now = time.time()
        if now - start > wall:
            kill_group(proc)
            proc.wait()
            sel.close()
            sys.exit(124)
        if now - last_out > idle:
            kill_group(proc)
            proc.wait()
            sel.close()
            sys.exit(125)

    # Drain remaining output after process exits
    while True:
        chunk = os.read(proc.stdout.fileno(), 8192)
        if not chunk:
            break
        sys.stdout.buffer.write(chunk)

    sel.close()
    sys.exit(proc.returncode)


if __name__ == "__main__":
    main()
