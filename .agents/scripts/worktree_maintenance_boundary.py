#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Candidate-local user-space observations, never historical completion evidence.

No service management, privileged inspector, session stops or receipt mutations.
Unknown process visibility retains the source; a plan is not an idle receipt.
"""

import os
from pathlib import Path
import sys

import worktree_process_proc as processes


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def observe():
    """Bind repeated checks to the current unprivileged Linux execution context."""
    require(sys.platform == "linux" and os.getuid() != 0,
            "maintenance:requires-unprivileged-linux")
    boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    require(bool(boot), "maintenance:boot-identity-unavailable")
    return {"uid": os.getuid(), "boot_id": boot, "mode": "user-space"}


def require_unused(path):
    """Reuse the unprivileged observer without guessing denied processes' CWDs."""
    require(path.stat().st_uid == os.getuid(), "maintenance:source-owner-mismatch")
    try:
        paths, denied = processes.collect(Path("/proc"))
    except (OSError, UnicodeError) as error:
        raise ValueError("maintenance:cwd-visibility-unusable") from error
    source = str(path)
    require(not any(cwd == source or cwd.startswith(source + "/") for cwd in paths),
            "maintenance:active-cwd")
    require(not denied, "maintenance:cwd-visibility-degraded")
    require(bool(paths), "maintenance:cwd-visibility-unusable")
