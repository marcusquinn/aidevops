#!/usr/bin/python3 -I
"""Read one same-user Linux process CWD for the worktree removal guard.

Install a root-owned copy with a single-executable sudoers rule. Never run
this from a writable worktree through sudo. Output is a path, not a verdict.
"""

import os
import re
import sys


def uid_fields_accepted(values: list, sudo_uid: int) -> bool:
    """Return True when a /proc Uid: line belongs to the invoking user.

    The real UID must be the invoking user. Effective, saved and filesystem
    UIDs may be that user or root, which covers same-user setuid-root helpers
    such as `fusermount3 auto_unmount` or an open `sudo` parent (GH#32871).
    Any other UID, including a root real UID, is another identity.
    """
    if sudo_uid <= 0 or len(values) != 4:
        return False
    if not all(re.fullmatch(r"[0-9]+", value) for value in values):
        return False
    uids = [int(value) for value in values]
    if uids[0] != sudo_uid:
        return False
    return all(uid in (sudo_uid, 0) for uid in uids[1:])


def owned_by_invoker(pid: str, sudo_uid: int) -> bool:
    with open(f"/proc/{pid}/status", encoding="ascii") as status:
        for line in status:
            if line.startswith("Uid:\t"):
                return uid_fields_accepted(line.split()[1:], sudo_uid)
    raise ValueError("process UID is unavailable")


def main() -> int:
    try:
        if os.geteuid() != 0 or len(sys.argv) != 2:
            raise ValueError("privileged invocation is required")
        pid = sys.argv[1]
        sudo_uid = os.environ.get("SUDO_UID", "")
        if not re.fullmatch(r"[1-9][0-9]*", pid) or not re.fullmatch(r"[1-9][0-9]*", sudo_uid):
            raise ValueError("invoking identity is invalid")
        proc_dir = f"/proc/{pid}"
        invoker_uid = int(sudo_uid)
        before = os.stat(proc_dir, follow_symlinks=False)
        if not owned_by_invoker(pid, invoker_uid):
            raise ValueError("process owner does not match the invoking user")
        cwd = os.readlink(f"{proc_dir}/cwd")
        after = os.stat(proc_dir, follow_symlinks=False)
        if before.st_ino != after.st_ino or not owned_by_invoker(pid, invoker_uid):
            raise ValueError("process identity changed during inspection")
        if not cwd.startswith("/") or any(ord(character) < 32 or ord(character) == 127 for character in cwd):
            raise ValueError("process CWD is not a safe absolute path")
    except (OSError, ValueError):
        return 1
    print(cwd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
