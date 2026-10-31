#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validate sealed lifetime receipts and optional archive recovery evidence."""

import worktree_lifetime_idle as idle_policy
import worktree_lifetime_owner as owner_lifetime


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def proof(record, source_inode):
    require(not record.get("creation_pending"), "replacement creation has no completed admission")
    require(record["state"] == "sealed" and record["identity"]["source_inode"] == source_inode,
            "no matching sealed generation")
    require(record.get("sealed_at", 0) > 0, "missing sealing receipt")
    if record.get("manager") == owner_lifetime.MANAGER:
        require(bool(record["launches"]), "missing owner admission evidence")
        owner_lifetime.require_admission_observed(record)
        for launch in record["launches"]:
            if launch.get("completion_evidence") is None:
                from worktree_lifetime_reconcile import validate_quiescence
                validate_quiescence(launch)
                continue
            require(launch.get("kind") == owner_lifetime.KIND and
                    launch.get("completion_evidence") == "systemd-cgroup-v1" and
                    launch.get("quiescence") and not launch.get("admission_cancelled"),
                    "missing owner completion receipt")
        # Only closed managed invocations reach this point. Validate their durable
        # receipts below, just like Pulse; arbitrary empty cgroups never qualify.
    if not record["launches"]:
        require(record.get("admission_cancelled") is True, "missing admission cancellation")
    for launch in record["launches"]:
        if record.get("manager") == owner_lifetime.MANAGER and launch.get("completion_evidence") is None:
            continue  # Independently validated observation receipt above, not a unit receipt.
        if launch.get("admission_cancelled") is True:
            require(launch["invocation"] is None, "admitted work cannot be cancelled")
            continue
        snapshot = launch.get("quiescence", {})
        require(snapshot.get("InvocationID") == launch["invocation"] and bool(launch["invocation"]),
                "invalid receipt invocation")
        require(snapshot.get("MainPID") == "0" and not snapshot.get("Job"), "receipt has pending work")
        require(snapshot.get("ExitType") == "cgroup" and snapshot.get("RemainAfterExit") == "yes"
                and snapshot.get("Restart") == "no", "invalid receipt lifetime contract")
        require((snapshot.get("ActiveState"), snapshot.get("SubState")) in
                (("active", "exited"), ("failed", "failed")), "invalid descendant receipt")


def inspect(record, path, extra, connection, verify_identity):
    require(len(extra) <= 1, "invalid source identity")
    if not extra:
        verify_identity(record, path)
        observed = path.stat()
        source_inode = f"{observed.st_dev}:{observed.st_ino}"
    else:
        source_inode = extra[0]
    proof(record, source_inode)
    if "archive_operation" in record:
        from worktree_lifetime_archive import require_verified
        require(record["archive_operation"]["phase"] in ("verified", "removed"),
                "archive operation is not removal-ready")
        if not extra:
            idle_policy.owner_clear(connection, str(path))
        require_verified(record, source=not extra)
