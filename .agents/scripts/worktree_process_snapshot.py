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
import re
import subprocess
import sys
import time

import worktree_lifetime_owner as owner


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
            directory = Path("/proc") / str(pid)
            try:
                if directory.stat().st_uid != uid:
                    raise ValueError("process ownership changed")
                stat = (directory / "stat").read_text().rsplit(")", 1)[1].split()
                process = {"start": stat[19], "state": stat[0], "cgroup": None}
                if not process["start"].isdecimal():
                    raise ValueError("invalid process start")
                try:
                    groups = [line[3:] for line in (directory / "cgroup").read_text().splitlines()
                              if line.startswith("0::")]
                    if len(groups) == 1:
                        process["cgroup"] = groups[0]
                    else:
                        result["membership_unavailable"] = True
                except OSError:
                    result["membership_unavailable"] = True
                try:
                    arguments = (directory / "cmdline").read_bytes().decode(errors="replace").split("\0")
                    process["worker_worktree"] = worker_directory([value for value in arguments if value])
                except OSError:
                    process["worker_worktree"] = None
                    result["runtime_inspection_unavailable"].append(pid)
                result["processes"][pid] = process
            except FileNotFoundError:
                # A vanished task is normal; an inaccessible existing entry is not.
                if os.path.lexists(directory):
                    result["uncertain_pids"].append(pid)
            except (OSError, ValueError, IndexError):
                result["uncertain_pids"].append(pid)
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
    unknown = {"status": "unknown", "descendants": "unknown"}
    if snapshot.get("status") != "available":
        return unknown
    boot, pid, start = launch.get("boot_id"), launch.get("owner_pid"), launch.get("owner_start")
    from worktree_lifetime_reconcile import valid_boot, valid_process
    if not valid_process(launch) or not valid_boot(snapshot.get("boot_id")):
        return unknown
    if boot != snapshot["boot_id"]:
        return {"status": "previous-boot", "descendants": "previous-boot-ended"}
    if pid in snapshot["uncertain_pids"]:
        return unknown
    process = snapshot["processes"].get(pid)
    if process is None:
        return {"status": "pid-absent", "descendants": "unknown"}
    if process["state"] in ("Z", "X"):
        return unknown
    return {"status": "same-process-alive" if start == process["start"] else "pid-reused",
            "descendants": "unknown"}


def activity(record, snapshot):
    """Describe managed Pulse activity without reclassifying generic owner rows."""
    from worktree_lifetime_reconcile import valid_boot
    result = {"state": "unknown", "basis": "process-snapshot", "deletion_authorized": False,
              "scope": "registered-managed-launches"}
    if snapshot.get("status") != "available":
        return dict(result, reason="process-snapshot-unavailable")
    identity = record.get("identity") or {}
    if not isinstance(identity, dict):
        return dict(result, reason="invalid-worktree-identity")
    path = identity.get("path")
    if path is not None and not isinstance(path, str):
        return dict(result, reason="invalid-worktree-identity")
    explicit = [pid for pid, process in snapshot["processes"].items()
                if path and process.get("worker_worktree") == os.path.normpath(path)]
    if explicit:
        # Positive worker use also protects a legacy/manual tree, without
        # manufacturing Pulse provenance or a negative deletion permit.
        return dict(result, state="active", matching_processes=sorted(explicit),
                    reason="runtime-worker-directory-match")
    if record.get("manager") != "pulse":
        return dict(result, reason="pulse-management-unrecorded")
    creator = record.get("created_by") or {}
    if not isinstance(creator, dict) or creator.get("entrypoint") != "pulse":
        return dict(result, reason="pulse-provenance-unrecorded")
    launches = record.get("launches") or []
    if not isinstance(launches, list) or not launches or not valid_boot(snapshot.get("boot_id")):
        return dict(result, reason="worker-admission-pending")
    pending = False
    matched = set()
    for launch in launches:
        if not isinstance(launch, dict):
            pending = True
            continue
        if launch.get("admission_cancelled") is True:
            continue
        group, unit, invocation = (launch.get(key) for key in ("cgroup", "unit", "invocation"))
        if (not valid_boot(launch.get("boot_id")) or not isinstance(invocation, str)
                or re.fullmatch(r"[0-9a-f]{32}", invocation) is None
                or not isinstance(unit, str) or re.fullmatch(r"aidevops-worker-[A-Za-z0-9_-]+(?:\.service)?", unit) is None
                or not isinstance(group, str) or not group.startswith("/") or ".." in Path(group).parts):
            pending = True
            continue
        if launch["boot_id"] != snapshot.get("boot_id"):
            continue
        if group.rsplit("/", 1)[-1] != unit.removesuffix(".service") + ".service":
            pending = True
            continue
        for pid, process in snapshot["processes"].items():
            observed = process.get("cgroup")
            if observed and (observed == group or observed.startswith(group + "/")):
                matched.add(pid)
    if matched:
        return dict(result, state="active", matching_processes=sorted(matched))
    if (pending or snapshot["uncertain_pids"] or snapshot["membership_unavailable"]
            or snapshot.get("runtime_inspection_unavailable")):
        return dict(result, reason="process-or-admission-evidence-unavailable")
    return dict(result, state="not-observed", reason="no-matching-worker-process")
