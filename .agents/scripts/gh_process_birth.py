#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Stable process-birth tokens for transport reservation and lease liveness.

Re-exported by gh_transport_budget; callers keep importing it from there.
"""

from __future__ import annotations

import hashlib
import os
import subprocess
import sys
import time
from pathlib import Path

__all__ = ["process_birth"]


def _linux_boot_time() -> int:
    # Read again after clock steps, just as a fresh legacy ps invocation does.
    with Path("/proc/stat").open(encoding="ascii") as stream:
        for line in stream:
            if line.startswith("btime "):
                return int(line.split()[1])
    raise ValueError("missing Linux boot time")


def process_birth(pid: int) -> str:
    # Keep the persisted SHA256(lstart.strip()) format: old runtime bundles
    # compare tokens directly, so even a backwards-readable new prefix would
    # make an old reader incorrectly reap a live new reservation/queue lease.
    # procps lstart uses ctime(boot_time + start_ticks / CLK_TCK). time.ctime
    # likewise uses local time and fixed English names, independent of locale.
    try:
        if pid <= 0:
            return ""
        if sys.platform == "linux":
            # comm may contain non-UTF-8 bytes, spaces and closing parentheses;
            # fields after its final ')' start at field 3, making field 22 index 19.
            fields = Path(f"/proc/{pid}/stat").read_bytes().rsplit(b")", 1)[1].split()
            started = _linux_boot_time() + int(fields[19]) // os.sysconf("SC_CLK_TCK")
            value = time.ctime(started).encode()
        else:
            value = subprocess.check_output(
                ["ps", "-p", str(pid), "-o", "lstart="],
                stderr=subprocess.DEVNULL, timeout=2,
            ).strip()
        return hashlib.sha256(value).hexdigest() if value else ""
    except (OSError, ValueError, IndexError, OverflowError, subprocess.SubprocessError):
        return ""
