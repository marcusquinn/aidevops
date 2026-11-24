# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Serialize managed SSH handshakes, not the lifetime of connected sessions."""

import contextlib
import fcntl
import os

from tabby_session_config import authentication_endpoint
from tabby_session_state import lease, state_directory


@contextlib.contextmanager
def authentication_slot(state_path, host, create=True):
    key = "authentication-" + authentication_endpoint(host)
    with contextlib.ExitStack() as stack:
        try:
            directory = state_directory(state_path, create=create)
            stack.callback(os.close, directory)
            handle = stack.enter_context(lease(directory, key, create=create))
        except FileNotFoundError:
            if create:
                raise
            # Read-only list/doctor/dry runs must not initialize local state.
            yield lambda: None
            return
        # Keep the inode: removing it would split waiting processes' locks.
        fcntl.flock(handle.fd, fcntl.LOCK_EX)
        handle.held = True

        def release():
            if handle.held:
                fcntl.flock(handle.fd, fcntl.LOCK_UN)
                handle.held = False

        # Closing the descriptor also releases startup/failure/cancel paths.
        yield release
