"""Startup socket reservation tests (no model / ASR imports)."""

from __future__ import annotations

import errno
import io
import socket
import sys
import unittest
from contextlib import redirect_stderr
from unittest.mock import MagicMock

from local_dictation_server._socket import _reserve_server_socket


def _free_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


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


if __name__ == "__main__":
    unittest.main()
