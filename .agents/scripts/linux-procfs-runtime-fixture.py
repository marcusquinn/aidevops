#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Process fixtures and observer runs for linux-procfs-runtime-check.sh.

Runs as root inside a Linux container. Usage: fixture.py SCRIPTS_DIR [UID] [--forged].
Fixtures (names are set with PR_SET_NAME so reports can be pid-normalised):
  sshd           root parent of a privsep child
  sshd-priv      privsep child: setuid to UID without exec (kernel clears dumpable)
  gpg-agent      unattested non-dumpable process of UID
  forged-parent  (--forged) non-sshd parent of a forged sshd-named process
  forged         (--forged) sshd-named process of UID re-parented under forged-parent
Prints a stable report: per observer mode, lines with pids replaced by fixture names.
"""

import ctypes
import os
import subprocess
import sys
import time

PR_SET_DUMPABLE = 4
PR_SET_NAME = 15
LIBC = ctypes.CDLL(None, use_errno=True)


def set_name(name: str) -> None:
    LIBC.prctl(PR_SET_NAME, name.encode(), 0, 0, 0)


def drop(uid: int) -> None:
    os.setgroups([])
    os.setgid(uid)
    os.setuid(uid)


class Ready:
    """Pipe on which a child reports its pid once its credentials are final."""

    def __init__(self) -> None:
        self.r, self.w = os.pipe()

    def write(self, pid: int) -> None:
        os.write(self.w, f"{pid}\n".encode())

    def read(self) -> int:
        return int(os.read(self.r, 32).split()[0])


def idle() -> None:
    time.sleep(60)
    os._exit(0)


def privsep(uid: int, names: dict) -> None:
    ready = Ready()
    parent = os.fork()
    if parent == 0:
        set_name("sshd")
        if os.fork() == 0:
            set_name("sshd-priv")
            drop(uid)  # no exec: dumpable stays cleared by the kernel
            ready.write(os.getpid())
            idle()
        idle()
    names[parent] = "sshd"
    names[ready.read()] = "sshd-priv"


def unattested(uid: int, names: dict) -> None:
    ready = Ready()
    if os.fork() == 0:
        set_name("gpg-agent")
        drop(uid)
        LIBC.prctl(PR_SET_DUMPABLE, 0, 0, 0, 0)
        ready.write(os.getpid())
        idle()
    pid = ready.read()
    names[pid] = "gpg-agent"


def forged(uid: int, names: dict) -> None:
    ready = Ready()
    holder = os.fork()
    if holder == 0:
        set_name("bash")
        if os.fork() == 0:
            set_name("sshd")
            drop(uid)
            ready.write(os.getpid())
            idle()
        idle()
    names[holder] = "forged-parent"
    names[ready.read()] = "forged"


def observe(scripts: str, uid: int, mode: list, names: dict) -> list:
    command = ["python3", os.path.join(scripts, "worktree_process_proc.py")] + mode
    result = subprocess.run(
        command, capture_output=True, text=True, preexec_fn=lambda: drop(uid), check=False
    )
    lines = []
    for raw in result.stdout.splitlines():
        fields = raw.split("\t")
        pids = [int(f) for f in fields if f.isdigit()]
        if pids and pids[0] not in names:
            continue  # container-internal process, not a fixture
        lines.append("\t".join(names.get(int(f), f) if f.isdigit() else f for f in fields))
    return [f"exit={result.returncode}"] + sorted(lines)


def main(arguments: list) -> int:
    scripts = arguments[0]
    uid = int(arguments[1]) if len(arguments) > 1 and arguments[1].isdigit() else 1000
    names: dict = {}
    privsep(uid, names)
    unattested(uid, names)
    if "--forged" in arguments:
        forged(uid, names)
    time.sleep(0.5)
    for mode in (["denied"], ["paths"], ["cwdmap", "/proc"]):
        print(f"## {' '.join(mode)} (uid {uid})")
        for line in observe(scripts, uid, mode, names):
            print(line)
    for pid in list(names):
        try:
            os.kill(pid, 9)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
