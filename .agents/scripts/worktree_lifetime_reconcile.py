#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Persist completion of recorded parent processes without inventing unit receipts.

Parent completion is distinct from descendant quiescence and source deletion.
All mutations run inside the existing registry writer transaction. Old launches
remain in the generation history; new admission appends rather than overwrites.
"""

import re
import time

import worktree_lifetime_owner as owner


IDENTITY_FIELDS = ("boot_id", "owner_pid", "owner_start", "cgroup", "cgroup_inode", "namespace")
ENDED = ("previous-boot", "pid-absent", "pid-reused")


def identity(launch):
    return {key: launch.get(key) for key in IDENTITY_FIELDS}


def valid_boot(value):
    return (isinstance(value, str) and
            re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", value) is not None)


def valid_process(launch):
    if not isinstance(launch, dict) or launch.get("kind") != owner.KIND:
        return False
    pid, start = launch.get("owner_pid"), launch.get("owner_start")
    if type(pid) is not int or not isinstance(start, str):
        return False
    return valid_boot(launch.get("boot_id")) and pid > 0 and start.isdecimal()


def valid_timestamp(value):
    return type(value) in (int, float) and 0 < value <= time.time()


def finished(launch):
    if not valid_process(launch):
        return False
    receipt = launch.get("process_completion")
    if not isinstance(receipt, dict):
        return False
    return all((receipt.get("schema") == 1, receipt.get("identity") == identity(launch),
                receipt.get("reason") in ENDED, valid_timestamp(receipt.get("observed_at"))))


def observations(record, source, snapshot=None):
    """Report cached completions and fresh unfinished-process observations only."""
    if source != "present" or record.get("manager") != owner.MANAGER:
        return {}
    from worktree_process_snapshot import recorded_status
    return {"recorded_processes": [
        {"status": item["process_completion"]["reason"], "persisted": True}
        if finished(item) else (recorded_status(item, snapshot) if snapshot is not None
                               else owner.recorded_process_status(item))
        for item in record.get("launches", [])]}


def completion_status(launch, snapshot):
    from worktree_process_snapshot import recorded_status
    observation = (recorded_status(launch, snapshot) if snapshot is not None
                   else owner.recorded_process_status(launch))
    status = observation["status"]
    if snapshot is not None and status in ENDED:
        # Recheck negative evidence inside the writer transaction: admission
        # may have changed since this process census was taken.
        status = owner.recorded_process_status(launch)["status"]
    return status


def reconcile(record, snapshot=None):
    owner.require(record.get("manager") == owner.MANAGER, "not an owner-observed lifetime")
    owner.require_admission_observed(record)
    launches = record.get("launches")
    owner.require(isinstance(launches, list) and bool(launches), "missing launch history")
    counts = {"finished": 0, "active": 0, "unknown": 0}
    for launch in launches:
        if not valid_process(launch):
            counts["unknown"] += 1
            continue
        if not finished(launch):
            status = completion_status(launch, snapshot)
            if status in ENDED:
                launch["process_completion"] = {"schema": 1, "identity": identity(launch),
                                                "reason": status, "observed_at": time.time()}
            else:
                counts["active" if status == "same-process-alive" else "unknown"] += 1
        if finished(launch):
            counts["finished"] += 1
    # A summary, not a seal or deletion permit. Cleanup must still validate its
    # own completion, owner, policy, archive and generation-fencing contracts.
    record["process_reconciliation"] = dict(counts, observed_at=time.time())
    return counts


def quiescence(launch):
    """Only a boot transition proves all legacy descendants ended without a unit contract."""
    owner.require(finished(launch), "recorded process is not reconciled as finished")
    before = owner.boot_id()
    owner.require(valid_boot(before) and before != launch["boot_id"],
                  "same-boot parent ended without managed descendant-completion evidence")
    owner.require(owner.boot_id() == before, "boot changed during observation")
    return {"schema": "owner-observation-quiescence/v1", "identity": identity(launch),
            "process_completion": dict(launch["process_completion"]), "group": "previous-boot-ended",
            "observed_boot": before, "observed_at": time.time()}


def validate_quiescence(launch):
    invalid = "invalid observation completion receipt"
    owner.require(finished(launch), invalid)
    receipt = launch.get("observation_quiescence", {})
    owner.require(isinstance(receipt, dict), invalid)
    owner.require(all((receipt.get("schema") == "owner-observation-quiescence/v1",
                       receipt.get("identity") == identity(launch),
                       receipt.get("process_completion") == launch.get("process_completion"),
                       receipt.get("group") == "previous-boot-ended",
                       valid_boot(receipt.get("observed_boot")),
                       receipt.get("observed_boot") != launch["boot_id"],
                       valid_timestamp(receipt.get("observed_at")))), invalid)


def reconcile_entries(observed):
    """Persist a preselected bounded registry batch without sealing or removing."""
    from pathlib import Path
    import sqlite3
    import subprocess
    import worktree_lifetime_archive as archive
    result = {"registry": observed["status"], "truncated": observed["truncated"],
              "records": 0, "finished": 0, "active": 0, "unknown": 0, "deferred": 0}
    managed = archive.managed_module()
    from worktree_process_snapshot import capture, summary
    snapshot = capture()
    result["process_snapshot"] = summary(snapshot)
    for entry in observed["entries"]:
        if entry.get("source") != "present" or "recorded_processes" not in entry:
            continue
        try:
            with archive.transaction() as connection:
                record = managed.load(connection, entry["path"])
                managed.verify_identity(record, Path(entry["path"]))
                counts = reconcile(record, snapshot)
                managed.save(connection, record)
            result["records"] += 1
            for key in counts:
                result[key] += counts[key]
        except (OSError, ValueError, KeyError, TypeError, sqlite3.Error, subprocess.SubprocessError):
            result["deferred"] += 1
    return result
