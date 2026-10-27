#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""One rootless process census, joined to lifecycle records, never deletion proof.

No CWD, environment, dispatch-ledger or retained-unit listing is read. Only the
worker role and explicit directory are extracted from known runtime launchers;
raw arguments are never retained or reported. Unknown membership is not absence.
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
            options[argument] = arguments[index + 1]
    directory = options.get("--dir", "")
    if options.get("--role") == "worker" and Path(directory).is_absolute():
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
