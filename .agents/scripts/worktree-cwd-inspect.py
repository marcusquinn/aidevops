#!/usr/bin/python3 -I
"""Inspect same-user Linux process references for the worktree removal guard.

Install a root-owned copy with a single-executable sudoers rule. Never run
this from a writable worktree through sudo. Legacy output is a CWD path;
--references emits bound census evidence, never deletion authority.

The interpreter is deliberately absolute, not `/usr/bin/env python3`: this
runs as root via sudo, where an env lookup could follow the caller's PATH.
The installing operator rewrites line 1 to the root-owned python3 of the host
(see reference/worktree-cwd-visibility.md).
"""

import json
import os
from pathlib import Path
import re
import signal
import stat
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


def task_identity(task: Path, sudo_uid: int) -> tuple:
    """Bind a permitted task to its inode and kernel start time, never its name."""
    before = task.stat()
    fields = dict(line.split(":", 1) for line in
                  (task / "status").read_text(encoding="ascii").splitlines() if ":" in line)
    if not uid_fields_accepted(fields.get("Uid", "").split(), sudo_uid):
        raise ValueError("process owner does not match the invoking user")
    start = int((task / "stat").read_text(encoding="ascii").rsplit(")", 1)[1].split()[19])
    after = task.stat()
    if start < 0 or (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
        raise ValueError("process identity changed during inspection")
    return after.st_dev, after.st_ino, start


def directory_identity(candidate: Path, sudo_uid: int) -> tuple:
    """Only inspect a canonical directory owned by the invoking user."""
    if not candidate.is_absolute() or candidate.resolve(strict=True) != candidate:
        raise ValueError("canonical candidate required")
    info = candidate.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != sudo_uid:
        raise ValueError("candidate owner does not match the invoking user")
    return info.st_dev, info.st_ino


def holds_candidate(reference: Path, candidate: Path) -> bool:
    raw = os.readlink(reference)
    # The suffix can be a literal filename, not only a kernel annotation.
    targets = (Path(raw), Path(raw.removesuffix(" (deleted)")))
    return any(target == candidate or candidate in target.parents for target in targets)


def reference_report(pid: str, candidate_text: str, sudo_uid: int) -> dict:
    """Observe all task CWD/fd tables; emit no paths or descriptor contents."""
    if (not re.fullmatch(r"[1-9][0-9]*", pid) or len(candidate_text) > 4096
            or any(ord(character) < 32 or ord(character) == 127 for character in candidate_text)):
        raise ValueError("invalid reference request")
    candidate = Path(candidate_text)
    directory = directory_identity(candidate, sudo_uid)
    process = Path("/proc") / pid
    identity = task_identity(process, sudo_uid)
    tasks = list((process / "task").iterdir())
    if not tasks or any(not task.name.isdecimal() for task in tasks):
        raise ValueError("thread inventory unavailable")
    identities = {task.name: task_identity(task, sudo_uid) for task in tasks}
    held = False
    for task in tasks:
        held = holds_candidate(task / "cwd", candidate) or held
        for descriptor in (task / "fd").iterdir():
            try:
                held = holds_candidate(descriptor, candidate) or held
            except FileNotFoundError:
                continue  # Independently closed descriptor; task identity is rechecked below.
    after = {task.name: task_identity(task, sudo_uid)
             for task in (process / "task").iterdir()}
    if (after != identities or task_identity(process, sudo_uid) != identity
            or directory_identity(candidate, sudo_uid) != directory):
        raise ValueError("reference identities changed during inspection")
    return {"version": 1, "pid": int(pid), "start_ticks": identity[2],
            "directory": list(directory), "status": "held" if held else "clear"}


def main() -> int:
    try:
        if os.geteuid() != 0:
            raise ValueError("privileged invocation is required")
        sudo_uid = os.environ.get("SUDO_UID", "")
        if not re.fullmatch(r"[1-9][0-9]*", sudo_uid):
            raise ValueError("invoking identity is invalid")
        if len(sys.argv) == 4 and sys.argv[1] == "--references":
            # Bound the privileged child itself, not only its sudo parent's wait.
            signal.signal(signal.SIGALRM, signal.SIG_DFL)
            signal.alarm(2)
            try:
                report = reference_report(sys.argv[2], sys.argv[3], int(sudo_uid))
                print(json.dumps(report, sort_keys=True))
            finally:
                signal.alarm(0)
            return 0
        if len(sys.argv) != 2:
            raise ValueError("invalid inspector arguments")
        pid = sys.argv[1]
        if not re.fullmatch(r"[1-9][0-9]*", pid):
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
    except (OSError, ValueError, IndexError):
        return 1
    print(cwd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
