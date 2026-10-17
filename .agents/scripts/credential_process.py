#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bounded, shell-free execution for the credential backend and fixed helpers."""
import shutil
# Subprocess is required for gopass and local helpers, with argv-only execution.
import subprocess  # nosec B404


def run(args, data=None, timeout=5, check=False, capture=True):
    """Run caller-built argv, resolving the executable without shell interpolation.

    Callers select gopass, bash or a discovered trash backend; credential values
    are passed only through stdin, never interpreted as commands or logged.
    """
    executable = shutil.which(args[0])
    if executable is None:
        raise FileNotFoundError(args[0])
    # B603: fixed executable roles and argv-only execution; shell remains disabled.
    return subprocess.run(  # nosec B603
        [executable, *args[1:]], input=data, timeout=timeout, check=check,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.DEVNULL if capture else None,
    )


def trash_backend():
    if shutil.which('trash'):
        return ['trash']
    if shutil.which('gio'):
        return ['gio', 'trash']
    return None
