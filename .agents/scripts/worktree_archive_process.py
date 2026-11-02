#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Cooperative termination for archive verification children (GH#36468).

A SIGKILLed verifier cannot remove its scratch. These helpers turn signals
into ``SystemExit`` so ``finally`` blocks run, and bound children with
SIGTERM-then-SIGKILL to their whole process group.
"""

import contextlib
import os
import signal
import subprocess
import threading

TERMINATION_SIGNALS = (signal.SIGTERM, signal.SIGHUP)


@contextlib.contextmanager
def termination_as_exit():
    """Turn SIGTERM/SIGHUP into SystemExit so ``finally`` cleanup runs.

    Python's default disposition terminates without unwinding. Only the main
    thread may install handlers; elsewhere this is a no-op.
    """
    if threading.current_thread() is not threading.main_thread():
        yield
        return

    def leave(signum, _frame):
        raise SystemExit(128 + signum)

    previous = {number: signal.signal(number, leave) for number in TERMINATION_SIGNALS}
    try:
        yield
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


def _popen_options(options):
    """Translate run()-style keywords into Popen keywords; return (check, data)."""
    check = options.pop('check', False)
    if options.pop('capture_output', False):
        options.setdefault('stdout', subprocess.PIPE)
        options.setdefault('stderr', subprocess.PIPE)
    data = options.pop('input', None)
    if data is not None:
        options['stdin'] = subprocess.PIPE
    return check, data


def run_bounded(command, timeout, grace=10, **options):
    """``subprocess.run`` equivalent that lets the child clean up on timeout.

    The child gets its own session, so the whole tree is signalled. Timeout
    sends SIGTERM to the group, waits ``grace`` seconds, then SIGKILLs it.
    Raises ``subprocess.TimeoutExpired`` or ``CalledProcessError`` like run().
    """
    check, data = _popen_options(options)
    with subprocess.Popen(command, start_new_session=True, **options) as process:  # nosec B603
        try:
            stdout, stderr = process.communicate(data, timeout=timeout)
        except subprocess.TimeoutExpired:
            terminate_group(process, grace)
            stdout, stderr = process.communicate()
            raise subprocess.TimeoutExpired(command, timeout, output=stdout, stderr=stderr) from None
        except BaseException:
            terminate_group(process, grace)
            raise
    if check and process.returncode:
        raise subprocess.CalledProcessError(process.returncode, command, stdout, stderr)
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def terminate_group(process, grace):
    """SIGTERM the child's process group, then SIGKILL after ``grace`` seconds."""
    for number, wait in ((signal.SIGTERM, grace), (signal.SIGKILL, None)):
        try:
            os.killpg(process.pid, number)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=wait)
            return
        except subprocess.TimeoutExpired:
            continue
