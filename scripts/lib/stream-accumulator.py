#!/usr/bin/env python3
"""Stream accumulator for `claude -p --output-format stream-json`.

Reads JSON events from stdin one per line. Emits periodic heartbeat
lines on stdout so the parent's idle-timer (run_with_timeout.py) keeps
resetting during long LLM turns. On natural exit (the final `result`
event), passes that event through to stdout enhanced with
`_envelope: true` plus cost aliases. On SIGTERM or premature EOF,
synthesizes an envelope from accumulated state and tags it
`_partial: true` so the parent shell can still recover what the model
produced.

Also writes the envelope atomically to --envelope-out PATH on every
major state change, so even a SIGKILL leaves the latest snapshot
readable on disk for post-mortem.

Contract with the rest of the pipeline:
  * stdout carries ONLY heartbeats and the final envelope line — both
    valid single-line JSON. Downstream parsers should take the last
    line with `_envelope: true` and ignore lines with `_hb: true`.
  * stderr carries human diagnostics. Callers route stderr to a
    separate log (e.g. acc_stderr.log) before this is run inside the
    claude | accumulator pipe so claude's stderr does not corrupt
    the JSON stream.
  * Exit code 0 when a natural `result` event was seen. Exit code 2
    when the envelope had to be synthesized from a partial stream.

See PLAN-stabilization.md Phase A (A3) for the broader design.
"""

import argparse
import json
import os
import signal
import sys
import threading
import time


DEFAULT_HEARTBEAT_INTERVAL = 2.0
# Throttle envelope-out writes to at most once per PARTIAL_WRITE_INTERVAL
# seconds during streaming. A natural `result` event and final emission
# always force a write regardless of throttle.
PARTIAL_WRITE_INTERVAL = 1.0


def _log(msg: str) -> None:
    """Write a diagnostic line to stderr. Never stdout — stdout is the
    protocol channel."""
    try:
        sys.stderr.write(f"[stream-accumulator] {msg}\n")
        sys.stderr.flush()
    except Exception:
        pass


def _atomic_write(path: str, obj) -> None:
    """Write JSON to path atomically via tmp + os.replace."""
    tmp = f"{path}.tmp.{os.getpid()}"
    try:
        with open(tmp, "w") as f:
            json.dump(obj, f)
        os.replace(tmp, path)
    except Exception as e:
        _log(f"envelope-out write failed: {e}")
        # Best-effort cleanup
        try:
            os.unlink(tmp)
        except OSError:
            pass


class Accumulator:
    """In-memory aggregate of what we've seen on stdin so far."""

    def __init__(self, envelope_out=None):
        self.envelope_out = envelope_out
        self.events_seen = 0
        self.result_chunks = []  # assistant text deltas, in order
        self.latest_usage = None  # per-turn usage from assistant events
        self.latest_model = None
        self.latest_session_id = None
        self.model_usage = None  # from result event
        self.final_result_event = None
        self._last_partial_write = 0.0
        self._lock = threading.Lock()

    def handle(self, event: dict) -> None:
        self.events_seen += 1
        etype = event.get("type")
        if etype == "system":
            if event.get("subtype") == "init":
                # init carries session_id + model + mcp_servers
                sid = event.get("session_id")
                if sid:
                    self.latest_session_id = sid
                m = event.get("model")
                if m:
                    self.latest_model = m
        elif etype == "assistant":
            msg = event.get("message") or {}
            for block in msg.get("content") or []:
                if block.get("type") == "text":
                    txt = block.get("text")
                    if txt:
                        self.result_chunks.append(txt)
            if "usage" in msg:
                self.latest_usage = msg["usage"]
            if "model" in msg:
                self.latest_model = msg["model"]
            self._maybe_write_partial()
        elif etype == "rate_limit_event":
            # informational — no state change needed, but worth logging
            _log(f"rate_limit_event: {json.dumps(event)[:500]}")
        elif etype == "result":
            # final event — preserve the whole payload
            self.final_result_event = event
            if "usage" in event:
                self.latest_usage = event["usage"]
            if "modelUsage" in event:
                self.model_usage = event["modelUsage"]
            sid = event.get("session_id")
            if sid:
                self.latest_session_id = sid
            m = event.get("model")
            if m:
                self.latest_model = m
        else:
            _log(f"unknown event type: {etype!r}")

    def _maybe_write_partial(self) -> None:
        if not self.envelope_out:
            return
        now = time.time()
        if now - self._last_partial_write < PARTIAL_WRITE_INTERVAL:
            return
        self._last_partial_write = now
        _atomic_write(self.envelope_out, self.build_partial_envelope())

    def build_partial_envelope(self) -> dict:
        return {
            "_envelope": True,
            "_partial": True,
            "events_seen": self.events_seen,
            "session_id": self.latest_session_id,
            "model": self.latest_model,
            "result": "".join(self.result_chunks),
            "usage": self.latest_usage,
            "modelUsage": self.model_usage,
        }

    def build_final_envelope(self) -> dict:
        assert self.final_result_event is not None
        env = dict(self.final_result_event)
        env["_envelope"] = True
        env["_partial"] = False
        # Cost aliases — existing parsers variously look for total_cost_usd,
        # cost_usd, or cost. Populate all three so downstream code doesn't
        # have to change.
        total_cost = env.get("total_cost_usd")
        if total_cost is not None:
            env.setdefault("cost_usd", total_cost)
            env.setdefault("cost", total_cost)
        # Ensure `result` string is present for partial-vs-natural symmetry
        # (the CLI's result event already carries it, but be defensive).
        if "result" not in env:
            env["result"] = "".join(self.result_chunks)
        return env


def _install_signal_handlers(state: dict) -> None:
    """Ignore SIGTERM / SIGINT so we keep draining stdin after the
    parent's run_with_timeout.py terminates the process group. claude's
    death will close stdin; that's our exit trigger. If SIGKILL arrives
    we die immediately — the atomic envelope-out snapshot on disk is the
    recovery path for that case.

    We still record the fact that we were signalled, for logging.
    """

    def _handler(signum, _frame):
        state["signalled"] = signum
        _log(f"received signal {signum}; continuing to drain stdin")

    signal.signal(signal.SIGTERM, _handler)
    signal.signal(signal.SIGINT, _handler)


def _heartbeat_loop(acc: Accumulator, stop_event: threading.Event,
                    interval: float) -> None:
    """Emit a heartbeat JSON line every `interval` seconds until stopped.

    Heartbeats serve two purposes:
      * Reset the parent's idle-output timer during long claude turns.
      * Provide a progress signal to the session log.
    """
    while not stop_event.wait(interval):
        try:
            sys.stdout.write(
                json.dumps({"_hb": True, "events": acc.events_seen}) + "\n"
            )
            sys.stdout.flush()
        except (BrokenPipeError, ValueError):
            # stdout closed — nothing we can do, exit the thread.
            return
        except Exception as e:
            _log(f"heartbeat write failed: {e}")
            return


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Accumulate claude stream-json into a final envelope."
    )
    parser.add_argument(
        "--envelope-out",
        help="Path to write the latest envelope atomically "
             "(updated on state changes so SIGKILL still leaves a snapshot).",
    )
    parser.add_argument(
        "--heartbeat-interval",
        type=float,
        default=DEFAULT_HEARTBEAT_INTERVAL,
        help=f"Seconds between heartbeat lines on stdout "
             f"(default {DEFAULT_HEARTBEAT_INTERVAL}).",
    )
    parser.add_argument(
        "--no-heartbeat",
        action="store_true",
        help="Disable heartbeats (for local debugging).",
    )
    args = parser.parse_args()

    signal_state = {"signalled": None}
    _install_signal_handlers(signal_state)

    acc = Accumulator(envelope_out=args.envelope_out)

    stop_hb = threading.Event()
    hb_thread = None
    if not args.no_heartbeat:
        hb_thread = threading.Thread(
            target=_heartbeat_loop,
            args=(acc, stop_hb, args.heartbeat_interval),
            daemon=True,
        )
        hb_thread.start()

    # Main read loop.
    try:
        for line in sys.stdin:
            line = line.rstrip("\n").rstrip("\r")
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError as e:
                # Non-JSON on stdin (e.g. bleed-through from somewhere) —
                # log and skip. Do not propagate to stdout.
                _log(f"JSON parse error: {e}: {line[:200]!r}")
                continue
            try:
                acc.handle(event)
            except Exception as e:
                _log(f"handle error on event: {e}: {line[:200]!r}")
                continue
    except Exception as e:
        _log(f"stdin read error: {e}")

    # Stop heartbeats BEFORE emitting the final envelope so the envelope
    # is the last thing on stdout.
    stop_hb.set()
    if hb_thread is not None:
        hb_thread.join(timeout=args.heartbeat_interval + 0.5)

    if acc.final_result_event is not None:
        envelope = acc.build_final_envelope()
        exit_code = 0
    else:
        envelope = acc.build_partial_envelope()
        # Tag why we gave up, for diagnostics.
        if signal_state["signalled"] is not None:
            envelope["_signalled"] = signal_state["signalled"]
        exit_code = 2
        _log(
            f"no final result event; emitting partial envelope "
            f"(events_seen={acc.events_seen}, signalled={signal_state['signalled']})"
        )

    if acc.envelope_out:
        _atomic_write(acc.envelope_out, envelope)

    try:
        sys.stdout.write(json.dumps(envelope) + "\n")
        sys.stdout.flush()
    except (BrokenPipeError, ValueError) as e:
        _log(f"final envelope write failed: {e}")
        # We still have envelope-out as the recovery path.
        if not acc.envelope_out:
            return 3
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
