#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fail-closed Linux worktree path-reference census, separate from activity."""

import os
from pathlib import Path
import subprocess  # nosec B404 -- fixed stat invocation, never a shell
import sys
import time

import worktree_lifetime_owner as owner


NON_DUMPABLE_DAEMONS = frozenset({"ssh-agent", "gpg-agent", "(sd-pam)",
                                   "systemd", "sshd", "dbus-daemon"})


def worktree_birth(path):
    """Return an inode-bound birth-time lower bound, never ctime or mtime."""
    try:
        before = os.stat(path, follow_symlinks=False)
        value = subprocess.check_output(  # nosec B603 B607 -- fixed Linux stat command, path after --
            ["stat", "--format=%d:%i %W", "--", path], text=True,
            stderr=subprocess.DEVNULL, timeout=5).split()
        after = os.stat(path, follow_symlinks=False)
        identity = (before.st_dev, before.st_ino)
        if (identity == (after.st_dev, after.st_ino) and len(value) == 2 and
                value[0] == f"{identity[0]}:{identity[1]}" and value[1].isdecimal()):
            birth = int(value[1])
            if 0 < birth <= time.time():
                return birth
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return None


def predates_worktree(task, birth):
    """Only known daemon tasks older than this directory may be excluded."""
    if birth is None:
        return False
    try:
        stat = (task / "stat").read_text()
        comm, fields = stat.split("(", 1)[1].rsplit(")", 1)
        start = fields.split()[19]
        if comm not in NON_DUMPABLE_DAEMONS or not start.isdecimal() or int(start) <= 0:
            return False
        boot = [line.split()[1] for line in Path("/proc/stat").read_text().splitlines()
                if line.startswith("btime ")]
        if len(boot) != 1 or not boot[0].isdecimal():
            return False
        # btime is second-resolution: use its upper bound, not a rounded-down
        # start, so tasks within the boundary second remain uncertain.
        started_before = int(boot[0]) + 1 + int(start) / os.sysconf("SC_CLK_TCK") < birth
        return started_before and (task / "stat").read_text() == stat
    except (OSError, ValueError, IndexError, ZeroDivisionError):
        return False


def under_worktree(target, path):
    """Use component boundaries, including procfs links to deleted files."""
    target = target.removesuffix(" (deleted)")
    if not os.path.isabs(target):
        return False
    target = os.path.normpath(target)
    return target == path or target.startswith(path + os.sep)


def inspect_path_references(directory, path):
    """A missing fd can be a close race; all other unreadable state is unknown."""
    fields = (directory / "stat").read_text().rsplit(")", 1)[1].split()
    if fields[0] in ("Z", "X"):
        return False
    start = fields[19]
    owner.require(start.isdecimal(), "invalid task start")
    if under_worktree(os.readlink(directory / "cwd"), path):
        return True
    for descriptor in (directory / "fd").iterdir():
        try:
            target = os.readlink(descriptor)
        except FileNotFoundError:
            continue
        if under_worktree(target, path):
            return True
    for entry in (directory / "environ").read_bytes().split(b"\0"):
        key, separator, value = entry.partition(b"=")
        if separator and key in (b"PWD", b"AIDEVOPS_WORKTREE"):
            if under_worktree(os.fsdecode(value), path):
                return True
    owner.require((directory / "stat").read_text().rsplit(")", 1)[1].split()[19] == start,
                  "process changed during path census")
    return False


def require_proc_visibility():
    """Reject filtered proc mounts and nested views relative to mounted procfs."""
    namespace_pids = [line.split()[1:] for line in Path("/proc/self/status").read_text().splitlines()
                      if line.startswith("NSpid:")]
    owner.require(namespace_pids == [[str(os.getpid())]], "proc PID namespace mismatch")
    mounts = []
    for line in Path("/proc/self/mountinfo").read_text().splitlines():
        fields = line.split()
        if len(fields) > 6 and fields[4] == "/proc":
            separator = fields.index("-")
            owner.require(fields[separator + 1] == "proc", "not a procfs mount")
            mounts.append(fields[5].split(",") + fields[separator + 3].split(","))
    owner.require(len(mounts) == 1, "proc mount visibility unavailable")
    owner.require(not any(option.startswith("hidepid=") and option not in ("hidepid=0", "hidepid=off")
                          for option in mounts[0]), "filtered proc mount")


def collect_path_references(directory, path, result, birth=None):
    """Inspect all threads: unshared CWD and descriptor tables can differ."""
    for task in (directory / "task").iterdir():
        try:
            # Non-dumpable same-UID tasks have root-owned proc directories.
            # Read credentials, not proc inode ownership; include saved/fs UIDs.
            rows = [line.split()[1:] for line in (task / "status").read_text().splitlines()
                    if line.startswith("Uid:")]
            owner.require(len(rows) == 1 and len(rows[0]) == 4 and
                          all(value.isdecimal() for value in rows[0]), "task UID unavailable")
            if str(os.getuid()) not in rows[0]:
                continue
            try:
                result["references"] += int(inspect_path_references(task, path))
            except PermissionError:
                if predates_worktree(task, birth):
                    result["excluded_nondumpable"] = result.get("excluded_nondumpable", 0) + 1
                else:
                    result["uncertain"] += 1
        except FileNotFoundError:
            if os.path.lexists(task):
                result["uncertain"] += 1
        except (OSError, ValueError, IndexError):
            result["uncertain"] += 1


def path_census(path):
    """Fail closed except for aged non-dumpable daemons; expose counts only."""
    result = {"status": "unavailable", "observed_at": time.time(),
              "uid": os.getuid(), "references": 0, "uncertain": 0,
              "excluded_nondumpable": 0}
    if sys.platform != "linux":
        return result
    try:
        require_proc_visibility()
        boot = owner.boot_id()
        birth = worktree_birth(path)
        seen_self = False
        for directory in Path("/proc").iterdir():
            if not directory.name.isdecimal():
                continue
            try:
                seen_self |= int(directory.name) == os.getpid()
                collect_path_references(directory, path, result, birth)
            except FileNotFoundError:
                if os.path.lexists(directory):
                    result["uncertain"] += 1
            except (OSError, ValueError, IndexError):
                result["uncertain"] += 1
        owner.require(seen_self and owner.boot_id() == boot, "incomplete path census")
        result.update(status="available", boot_id=boot, observed_at=time.time())
    except (OSError, ValueError, IndexError):
        pass
    return result
