#!/usr/bin/python3 -I
"""Read one same-user Linux process CWD for the worktree removal guard.

Install a root-owned copy with a single-executable sudoers rule. Never run
this from a writable worktree through sudo. Output is a path, not a verdict.
"""

import os
import re
import sys


def owner_uid(pid: str) -> int:
    with open(f"/proc/{pid}/status", encoding="ascii") as status:
        for line in status:
            if line.startswith("Uid:\t"):
                values = line.split()[1:]
                if len(values) != 4 or len(set(values)) != 1:
                    raise ValueError("process identity is not stable")
                return int(values[0])
    raise ValueError("process UID is unavailable")


def main() -> int:
    if os.geteuid() != 0 or len(sys.argv) != 2:
        return 1
    pid = sys.argv[1]
    sudo_uid = os.environ.get("SUDO_UID", "")
    if not re.fullmatch(r"[1-9][0-9]*", pid) or not re.fullmatch(r"[1-9][0-9]*", sudo_uid):
        return 1
    try:
        proc_dir = f"/proc/{pid}"
        before = os.stat(proc_dir, follow_symlinks=False)
        if owner_uid(pid) != int(sudo_uid):
            return 1
        cwd = os.readlink(f"{proc_dir}/cwd")
        after = os.stat(proc_dir, follow_symlinks=False)
        if before.st_ino != after.st_ino or owner_uid(pid) != int(sudo_uid):
            return 1
        if not cwd.startswith("/") or any(ord(character) < 32 or ord(character) == 127 for character in cwd):
            return 1
    except (OSError, ValueError):
        return 1
    print(cwd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
