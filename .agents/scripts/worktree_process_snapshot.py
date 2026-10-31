#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""One rootless process census, joined to lifecycle records, never deletion proof.

No CWD, environment, dispatch-ledger or retained-unit listing is read. Only the
worker role and explicit directory are extracted from known runtime launchers;
raw arguments are never retained or reported. Unknown membership is not absence.
The separate path census below reads CWD/fd/environment references only when
sealing a finished legacy launch; it never retains environment contents.
"""

import os
from pathlib import Path
import subprocess
import sys
import time

import worktree_lifetime_owner as owner
from worktree_process_activity import activity as activity


def worker_directory(arguments):
    launchers = {"headless-runtime-helper.sh", "headless-runtime-worker.sh"}
    if not any(Path(argument).name in launchers for argument in arguments):
        return None
    options = {}
    for index, argument in enumerate(arguments[:-1]):
        if argument in ("--role", "--dir"):
            if argument in options:
                raise ValueError("ambiguous runtime worker options")
            options[argument] = arguments[index + 1]
    if "--role" not in options:
        raise ValueError("runtime worker role unavailable")
    directory = options.get("--dir", "")
    if options["--role"] == "worker":
        if not Path(directory).is_absolute():
            raise ValueError("runtime worker directory unavailable")
        return os.path.normpath(directory)
    return None


def process_cgroup(directory, result):
    try:
        groups = [line[3:] for line in (directory / "cgroup").read_text().splitlines()
                  if line.startswith("0::")]
    except OSError:
        groups = []
    if len(groups) == 1:
        return groups[0]
    result["membership_unavailable"] = True
    return None


def inspect_process(pid, uid, result):
    directory = Path("/proc") / str(pid)
    if directory.stat().st_uid != uid:
        raise ValueError("process ownership changed")
    stat = (directory / "stat").read_text().rsplit(")", 1)[1].split()
    if not stat[19].isdecimal():
        raise ValueError("invalid process start")
    process = {"start": stat[19], "state": stat[0], "cgroup": process_cgroup(directory, result)}
    try:
        arguments = (directory / "cmdline").read_bytes().decode(errors="replace").split("\0")
        process["worker_worktree"] = worker_directory([value for value in arguments if value])
    except OSError:
        process["worker_worktree"] = None
        result["runtime_inspection_unavailable"].append(pid)
    return process


def collect_process(pid, uid, result):
    try:
        result["processes"][pid] = inspect_process(pid, uid, result)
    except FileNotFoundError:
        # A vanished task is normal; an inaccessible existing entry is not.
        if os.path.lexists(Path("/proc") / str(pid)):
            result["uncertain_pids"].append(pid)
    except (OSError, ValueError, IndexError):
        result["uncertain_pids"].append(pid)


def capture():
    result = {"status": "unavailable", "observed_at": time.time(), "processes": {},
              "uncertain_pids": [], "membership_unavailable": False,
              "runtime_inspection_unavailable": []}
    if sys.platform != "linux":
        result["reason"] = "platform-not-supported"
        return result
    try:
        boot = owner.boot_id()
        output = subprocess.check_output(["ps", "-e", "-o", "pid=,uid="],
                                         text=True, stderr=subprocess.DEVNULL, timeout=10)
        for line in output.splitlines():
            fields = line.split()
            if len(fields) != 2 or not all(value.isdecimal() for value in fields):
                raise ValueError("invalid process census")
            pid, uid = map(int, fields)
            if uid != os.getuid():
                continue
            collect_process(pid, uid, result)
        if os.getpid() not in result["processes"] or owner.boot_id() != boot:
            raise ValueError("incomplete process census")
        result.update(status="available", boot_id=boot)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        result["reason"] = type(error).__name__
    return result


def summary(snapshot):
    return {key: snapshot[key] for key in ("status", "observed_at", "membership_unavailable")} | {
        "process_count": len(snapshot["processes"]),
        "uncertain_process_count": len(snapshot["uncertain_pids"]),
        "runtime_inspection_unavailable_count": len(snapshot.get("runtime_inspection_unavailable", [])),
        "reason": snapshot.get("reason")}


def recorded_status(launch, snapshot):
    """Match an already-recorded parent; this does not account for descendants."""
    result = {"status": "unknown", "descendants": "unknown"}
    from worktree_lifetime_reconcile import valid_boot, valid_process
    valid = snapshot.get("status") == "available" and valid_process(launch)
    if not valid or not valid_boot(snapshot.get("boot_id")):
        return result
    pid = launch["owner_pid"]
    process = snapshot["processes"].get(pid)
    if launch["boot_id"] != snapshot["boot_id"]:
        result.update(status="previous-boot", descendants="previous-boot-ended")
    elif pid in snapshot["uncertain_pids"]:
        pass
    elif process is None:
        result["status"] = "pid-absent"
    elif process["state"] not in ("Z", "X"):
        result["status"] = "same-process-alive" if launch["owner_start"] == process["start"] else "pid-reused"
    return result


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


def collect_path_references(directory, path, result):
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
            result["references"] += int(inspect_path_references(task, path))
        except FileNotFoundError:
            if os.path.lexists(task):
                result["uncertain"] += 1
        except (OSError, ValueError, IndexError):
            result["uncertain"] += 1


def path_census(path):
    """Fail closed on any inaccessible same-UID task; expose counts, not paths."""
    result = {"status": "unavailable", "observed_at": time.time(),
              "uid": os.getuid(), "references": 0, "uncertain": 0}
    if sys.platform != "linux":
        return result
    try:
        require_proc_visibility()
        boot = owner.boot_id()
        seen_self = False
        for directory in Path("/proc").iterdir():
            if not directory.name.isdecimal():
                continue
            try:
                seen_self |= int(directory.name) == os.getpid()
                collect_path_references(directory, path, result)
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
