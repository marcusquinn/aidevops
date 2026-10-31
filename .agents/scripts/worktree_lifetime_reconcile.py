#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Persist completion of recorded parent processes without inventing unit receipts.

Parent completion is distinct from descendant quiescence and source deletion.
All mutations run inside the existing registry writer transaction. Old launches
remain in the generation history; new admission appends rather than overwrites.
"""

import os
import re
import time

import worktree_lifetime_owner as owner


IDENTITY_FIELDS = ("boot_id", "owner_pid", "owner_start", "cgroup", "cgroup_inode", "namespace")
ENDED = ("previous-boot", "pid-absent", "pid-reused")
CENSUS_INTERVAL = 2


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


def quiescence(launch, worktree_identity=None, census_cache=None):
    """Require a boot transition or two complete, empty Linux path censuses."""
    owner.require(finished(launch), "recorded process is not reconciled as finished")
    before = owner.boot_id()
    owner.require(valid_boot(before), "boot identity unavailable")
    receipt = {"schema": "owner-observation-quiescence/v1", "identity": identity(launch),
               "process_completion": dict(launch["process_completion"]),
               "group": "previous-boot-ended", "observed_boot": before}
    if before == launch["boot_id"]:
        owner.require(isinstance(worktree_identity, dict) and
                      os.path.isabs(worktree_identity.get("path", "")) and
                      bool(worktree_identity.get("source_inode")),
                      "same-boot parent requires worktree generation identity")
        from worktree_process_snapshot import path_census
        # This cache belongs to one seal/authorization call, never the registry.
        key = (worktree_identity["path"], worktree_identity["source_inode"], os.getuid(), before)
        samples = census_cache.get(key) if census_cache is not None else None
        if samples is None:
            samples = []
            for index in range(2):
                if index:
                    time.sleep(CENSUS_INTERVAL)
                sample = path_census(worktree_identity["path"])
                owner.require(empty_census(sample, before), "same-boot process census active or unavailable")
                samples.append(sample)
            if census_cache is not None:
                census_cache[key] = samples
        owner.require(samples[1]["observed_at"] - samples[0]["observed_at"] >= CENSUS_INTERVAL,
                      "process census interval too short")
        owner.require(owner.recorded_process_status(launch)["status"] in ENDED,
                      "recorded parent no longer finished")
        receipt.update(group="same-boot-proc-census", worktree_identity=dict(worktree_identity),
                       samples=samples)
    owner.require(owner.boot_id() == before, "boot changed during observation")
    return dict(receipt, observed_at=time.time())


def empty_census(sample, boot):
    return isinstance(sample, dict) and all((
        sample.get("status") == "available", sample.get("boot_id") == boot,
        type(sample.get("uid")) is int and sample["uid"] == os.getuid(),
        type(sample.get("references")) is int and sample["references"] == 0,
        type(sample.get("uncertain")) is int and sample["uncertain"] == 0,
        valid_timestamp(sample.get("observed_at"))))


def validate_quiescence(launch, worktree_identity=None):
    invalid = "invalid observation completion receipt"
    owner.require(finished(launch), invalid)
    receipt = launch.get("observation_quiescence", {})
    owner.require(isinstance(receipt, dict), invalid)
    owner.require(all((receipt.get("schema") == "owner-observation-quiescence/v1",
                       receipt.get("identity") == identity(launch),
                       receipt.get("process_completion") == launch.get("process_completion"),
                       valid_boot(receipt.get("observed_boot")),
                       valid_timestamp(receipt.get("observed_at")))), invalid)
    if receipt.get("group") == "previous-boot-ended":
        owner.require(receipt["observed_boot"] != launch["boot_id"], invalid)
        return
    samples = receipt.get("samples")
    owner.require(receipt.get("group") == "same-boot-proc-census" and
                  receipt["observed_boot"] == launch["boot_id"] and
                  isinstance(worktree_identity, dict) and
                  receipt.get("worktree_identity") == worktree_identity and
                  isinstance(samples, list) and len(samples) == 2, invalid)
    owner.require(all(empty_census(sample, receipt["observed_boot"]) for sample in samples), invalid)
    owner.require(samples[1]["observed_at"] - samples[0]["observed_at"] >= CENSUS_INTERVAL and
                  samples[1]["observed_at"] <= receipt["observed_at"], invalid)


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
