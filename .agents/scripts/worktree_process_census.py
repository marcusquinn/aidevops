#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Fail-closed Linux worktree path-reference census, separate from activity.

An unreadable (non-dumpable) same-UID task stays uncertain unless kernel facts
the unprivileged user cannot forge attest that its code never entered the
worktree (GH#38428). Mutable task names never grant an exclusion. Uncertainty
is reported by class (counts only, no names or paths) so refusals explain why.
"""

from collections import Counter
import os
from pathlib import Path
import sys
import time

from worktree_census_resolution import apply_privileged_census
import worktree_lifetime_owner as owner
from worktree_process_attestation import session_class


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


def _record(result, key, kind, count=1):
    """Count a task; a census result also keeps the per-class breakdown."""
    result[key] += count
    classes = result.get(f"{key}_classes")
    if classes is not None and count:
        classes[kind] += count


def _unreadable_task(task, result):
    """Classify a task whose CWD is unreadable: attested session helper or uncertain."""
    attested = session_class(task)
    if attested:
        _record(result, "excluded_nondumpable", attested)
    else:
        # comm is mutable, so a name such as ssh-agent cannot prove the absence
        # of worktree references; only the privileged census can resolve this.
        _record(result, "uncertain", "nondumpable")


def collect_path_references(directory, path, result):
    """Inspect all threads: unshared CWD and descriptor tables can differ."""
    for task in (directory / "task").iterdir():
        try:
            # Non-dumpable same-UID tasks have root-owned proc directories.
            # Read credentials, not proc inode ownership; include saved/fs UIDs.
            (uids,) = [line.split()[1:] for line in (task / "status").read_text().splitlines()
                       if line.startswith("Uid:")]
            owner.require(len(uids) == 4 and all(map(str.isdecimal, uids)),
                          "task UID unavailable")
            if str(os.getuid()) not in uids:
                continue
            try:
                result["references"] += int(inspect_path_references(task, path))
            except PermissionError:
                _unreadable_task(task, result)
        except FileNotFoundError:
            _record(result, "uncertain", "racing", int(os.path.lexists(task)))
        except (OSError, ValueError, IndexError):
            _record(result, "uncertain", "unreadable")


def path_census(path, source_inode=None):
    """Fail closed for all unreadable task references; expose counts only."""
    result = {"status": "unavailable", "observed_at": time.time(),
              "uid": os.getuid(), "references": 0, "uncertain": 0,
              "excluded_nondumpable": 0, "uncertain_classes": Counter(),
              "excluded_nondumpable_classes": Counter()}
    if sys.platform != "linux":
        return result
    try:
        require_proc_visibility()
        boot = owner.boot_id()
        if source_inode is not None:
            owner.require(owner.inode(Path(path)) == source_inode, "worktree generation changed")
        seen_self = False
        for directory in Path("/proc").iterdir():
            if not directory.name.isdecimal():
                continue
            try:
                seen_self |= int(directory.name) == os.getpid()
                collect_path_references(directory, path, result)
            except FileNotFoundError:
                _record(result, "uncertain", "racing", int(os.path.lexists(directory)))
            except (OSError, ValueError, IndexError):
                _record(result, "uncertain", "unreadable")
        owner.require(seen_self and owner.boot_id() == boot, "incomplete path census")
        apply_privileged_census(path, result)
        if source_inode is not None:
            owner.require(owner.inode(Path(path)) == source_inode, "worktree generation changed")
        result.update(status="available", boot_id=boot, observed_at=time.time())
    except (OSError, ValueError, IndexError):
        pass
    # Receipts persist samples as JSON: keep plain, non-zero class counts.
    for key in ("uncertain_classes", "excluded_nondumpable_classes"):
        result[key] = {kind: count for kind, count in sorted(result[key].items()) if count}
    return result
