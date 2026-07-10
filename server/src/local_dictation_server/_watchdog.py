# Ported from github.com/T0mSIlver/voxmlx (MIT License)
# Copyright (c) the voxmlx contributors
"""Process-lifecycle helpers for managed launchers (parent watchdog, startup heartbeat)."""

from __future__ import annotations

import logging
import os
import sys
import threading
import time
from typing import TextIO

logger = logging.getLogger(__name__)

# Comfortably under the macOS supervisor's 600s inactivity window.
DEFAULT_STARTUP_HEARTBEAT_INTERVAL = 10.0


def parent_is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def start_parent_watchdog(
    parent_pid: int,
    poll_interval: float = 2.0,
    _exit=os._exit,
) -> threading.Thread:
    def watch_parent():
        while parent_is_alive(parent_pid):
            time.sleep(poll_interval)

        logger.info("Parent process %s exited; stopping voxmlx server", parent_pid)
        _exit(0)

    thread = threading.Thread(
        target=watch_parent,
        name="voxmlx-parent-watchdog",
        daemon=True,
    )
    thread.start()
    return thread


class StartupHeartbeat:
    """Periodic stderr lines during pre-ready startup so a silent model load
    still refreshes the supervisor's activity timer.

    Emits plain ``[startup] initializing, Ns elapsed`` lines — not HF/tqdm-shaped
    progress — then stops once the HTTP server is serving (or startup fails).
    """

    def __init__(
        self,
        interval: float = DEFAULT_STARTUP_HEARTBEAT_INTERVAL,
        stream: TextIO | None = None,
    ) -> None:
        self._interval = interval
        self._stream = sys.stderr if stream is None else stream
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._started_at: float | None = None

    def start(self) -> StartupHeartbeat:
        if self._thread is not None:
            return self
        self._stop.clear()
        self._started_at = time.monotonic()
        self._thread = threading.Thread(
            target=self._run,
            name="startup-heartbeat",
            daemon=True,
        )
        self._thread.start()
        return self

    def stop(self, join_timeout: float = 1.0) -> None:
        """Signal the heartbeat thread to exit and join briefly.

        Idempotent and safe from any thread. A short join keeps shutdown from
        blocking; the thread is daemon so process exit is never delayed.
        """
        self._stop.set()
        thread = self._thread
        if thread is None:
            return
        thread.join(timeout=join_timeout)
        if not thread.is_alive():
            self._thread = None

    def _run(self) -> None:
        started_at = self._started_at
        assert started_at is not None
        while not self._stop.wait(timeout=self._interval):
            elapsed = time.monotonic() - started_at
            print(
                f"[startup] initializing, {elapsed:.0f}s elapsed",
                file=self._stream,
                flush=True,
            )


def start_startup_heartbeat(
    interval: float = DEFAULT_STARTUP_HEARTBEAT_INTERVAL,
    stream: TextIO | None = None,
) -> StartupHeartbeat:
    """Start a daemon-thread startup heartbeat; call ``.stop()`` once ready."""
    return StartupHeartbeat(interval=interval, stream=stream).start()
