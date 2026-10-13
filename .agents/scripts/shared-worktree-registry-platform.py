#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Small filesystem/process adapters; unknown evidence never proves absence."""

from datetime import datetime, timezone
import os
import sys


def pid_absent(pid: int) -> bool:
    # Signal zero is a POSIX liveness probe, not a portable Windows operation.
    if os.name != "posix" or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except (PermissionError, OSError):
        return False
    return False


def started_after(created_at: str, process_lstart: str) -> bool:
    created = datetime.strptime(created_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    started = datetime.strptime(process_lstart.strip(), "%a %b %d %H:%M:%S %Y")
    return started.astimezone(timezone.utc) > created


def main(args: list[str]) -> int:
    try:
        if len(args) == 2 and args[0] == "normalize":
            print(os.path.realpath(args[1]))
            return 0
        if len(args) == 2 and args[0] == "pid-absent":
            return 0 if pid_absent(int(args[1])) else 1
        if len(args) == 3 and args[0] == "started-after":
            return 0 if started_after(args[1], args[2]) else 1
    except (OSError, ValueError, OverflowError):
        return 1
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
