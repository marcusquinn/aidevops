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
    return (isinstance(launch, dict) and launch.get("kind") == owner.KIND and valid_boot(launch.get("boot_id"))
            and type(launch.get("owner_pid")) is int and launch["owner_pid"] > 0
            and isinstance(launch.get("owner_start"), str) and launch["owner_start"].isdecimal())


def finished(launch):
    if not valid_process(launch):
        return False
    receipt = launch.get("process_completion")
    return (valid_process(launch) and isinstance(receipt, dict) and receipt.get("schema") == 1
            and receipt.get("identity") == identity(launch)
            and receipt.get("reason") in ENDED
            and type(receipt.get("observed_at")) in (int, float)
            and 0 < receipt["observed_at"] <= time.time())


def reconcile(record):
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
            observation = owner.recorded_process_status(launch)
            status = observation["status"]
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
    receipt = launch.get("observation_quiescence", {})
    owner.require(finished(launch) and isinstance(receipt, dict)
                  and receipt.get("schema") == "owner-observation-quiescence/v1"
                  and launch.get("kind") == owner.KIND
                  and receipt.get("identity") == identity(launch)
                  and receipt.get("process_completion") == launch.get("process_completion")
                  and receipt.get("group") == "previous-boot-ended"
                  and valid_boot(receipt.get("observed_boot"))
                  and receipt["observed_boot"] != launch["boot_id"]
                  and type(receipt.get("observed_at")) in (int, float)
                  and 0 < receipt["observed_at"] <= time.time(), "invalid observation completion receipt")
