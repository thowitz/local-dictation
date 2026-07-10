"""TCP socket reservation helpers for server startup."""

from __future__ import annotations

import errno
import socket
import sys
from collections.abc import Callable
from typing import Any


def _reserve_server_socket(
    host: str,
    port: int,
    *,
    _exit: Callable[[int], Any] = sys.exit,
) -> socket.socket:
    """Bind and listen on ``(host, port)`` before model creation.

    On ``EADDRINUSE``, emit a stable fatal line to stderr and exit non-zero
    without creating the model. The returned socket is what uvicorn serves on.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((host, port))
        sock.listen()
    except OSError as exc:
        sock.close()
        if exc.errno == errno.EADDRINUSE:
            print(
                f"LOCAL_DICTATION_FATAL kind=port_in_use host={host} port={port}",
                file=sys.stderr,
                flush=True,
            )
            _exit(1)
            raise SystemExit(1)  # when _exit is mocked and returns
        raise
    return sock
