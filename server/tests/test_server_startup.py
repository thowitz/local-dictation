"""Startup socket reservation and liveness-heartbeat tests (no model / ASR imports)."""

from __future__ import annotations

import errno
import io
import re
import socket
import sys
import time
import unittest
from contextlib import redirect_stderr
from unittest.mock import MagicMock

from local_dictation_server._socket import _reserve_server_socket
from local_dictation_server._watchdog import start_startup_heartbeat


def _free_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def _startup_heartbeat_lines(buf: io.StringIO) -> list[str]:
    return [
        line
        for line in buf.getvalue().splitlines()
        if line.startswith("[startup]")
    ]


class TestReserveServerSocket(unittest.TestCase):
    def test_reservation_owns_port_then_releases(self) -> None:
        port = _free_loopback_port()
        reserved = _reserve_server_socket("127.0.0.1", port)
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as rival:
                rival.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                with self.assertRaises(OSError) as ctx:
                    rival.bind(("127.0.0.1", port))
                self.assertEqual(ctx.exception.errno, errno.EADDRINUSE)
        finally:
            reserved.close()

        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as after:
            after.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            after.bind(("127.0.0.1", port))

    def test_port_in_use_emits_stable_fatal_and_exits(self) -> None:
        # Reservation is fully separable from create_app: this module never
        # imports mlx/voxmlx, so a port collision cannot invoke the model factory.
        port = _free_loopback_port()
        holder = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        holder.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        holder.bind(("127.0.0.1", port))
        holder.listen()
        exit_seam = MagicMock(side_effect=SystemExit(1))
        stderr = io.StringIO()
        try:
            with redirect_stderr(stderr):
                with self.assertRaises(SystemExit) as cm:
                    _reserve_server_socket(
                        "127.0.0.1",
                        port,
                        _exit=exit_seam,
                    )
            self.assertEqual(cm.exception.code, 1)
        finally:
            holder.close()

        exit_seam.assert_called_once_with(1)
        fatal = stderr.getvalue()
        self.assertIn("LOCAL_DICTATION_FATAL kind=port_in_use", fatal)
        self.assertIn("host=127.0.0.1", fatal)
        self.assertIn(f"port={port}", fatal)
        self.assertNotIn("local_dictation_server.server", sys.modules)
        self.assertFalse(
            any(
                name.startswith("mlx") or name.startswith("voxmlx")
                for name in sys.modules
            )
        )


class TestStartupHeartbeat(unittest.TestCase):
    def test_emits_during_slow_load_then_stops_when_ready(self) -> None:
        """Simulated blocking load: heartbeats at the interval, then silence after ready."""
        stderr = io.StringIO()
        interval = 0.05
        heartbeat = start_startup_heartbeat(interval=interval, stream=stderr)
        try:
            # Stand-in for create_app / MLX load: block longer than two intervals.
            time.sleep(interval * 2.5)
            during_load = _startup_heartbeat_lines(stderr)
            self.assertGreaterEqual(
                len(during_load),
                2,
                f"expected >=2 heartbeats during load, got {during_load!r}",
            )
            for line in during_load:
                self.assertRegex(
                    line,
                    re.compile(r"^\[startup\] initializing, \d+s elapsed$"),
                )
                # Must not look like HF/tqdm download progress.
                self.assertNotIn("%|", line)
                self.assertNotRegex(
                    line, r"(?i)download|fetching|huggingface|hf_hub|safetensors"
                )
                self.assertNotRegex(line, r"\d+(\.\d+)?[GMK]/\d+(\.\d+)?[GMK]")

            # "Ready": stop as main does once the HTTP server is serving.
            heartbeat.stop()
            snapshot = stderr.getvalue()
            time.sleep(interval * 2.5)
            self.assertEqual(
                stderr.getvalue(),
                snapshot,
                "heartbeat must not emit after ready/stop",
            )
            # stop() is idempotent (mirrors main's finally after startup hook).
            heartbeat.stop()
        finally:
            heartbeat.stop()

        self.assertNotIn("local_dictation_server.server", sys.modules)
        self.assertFalse(
            any(
                name.startswith("mlx") or name.startswith("voxmlx")
                for name in sys.modules
            )
        )

    def test_stop_on_failed_startup_is_safe(self) -> None:
        stderr = io.StringIO()
        interval = 0.05
        heartbeat = start_startup_heartbeat(interval=interval, stream=stderr)
        try:
            time.sleep(interval * 1.5)
            raise RuntimeError("simulated load failure")
        except RuntimeError:
            heartbeat.stop()
        time.sleep(interval * 2)
        lines = _startup_heartbeat_lines(stderr)
        self.assertGreaterEqual(len(lines), 1)
        # No further lines after the failure-path stop.
        self.assertEqual(len(lines), len(_startup_heartbeat_lines(stderr)))


if __name__ == "__main__":
    unittest.main()
