#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Hold a kernel-backed repository verify lock until its owner releases it."""

import fcntl
import os
import sys
import time


def main() -> int:
    lock_path, ready_path, owner_pid_text = sys.argv[1:]
    owner_pid = int(owner_pid_text)
    with open(lock_path, "a+", encoding="utf-8") as lock_file:
        deadline = time.monotonic() + 5
        while True:
            try:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    return 1
                time.sleep(0.05)
        with open(ready_path, "w", encoding="utf-8") as ready_file:
            ready_file.write(str(os.getpid()))
        while os.path.exists(ready_path):
            try:
                os.kill(owner_pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
