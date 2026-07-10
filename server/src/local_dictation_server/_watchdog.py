# Ported from github.com/T0mSIlver/voxmlx (MIT License)
# Copyright (c) the voxmlx contributors
"""Parent process watchdog helpers for managed launchers."""

import logging
import os
import threading
import time

logger = logging.getLogger(__name__)


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
