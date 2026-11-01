# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Readiness and sealing observations (callers inject managed-lifetime ops)."""

import copy
from pathlib import Path


def inspect_record(ops, record: dict, path: Path, operation: str, extra: list[str]) -> None:
    connection = ops.connection
    reader = ops.READERS.get(operation)
    if reader:
        reader(record, path, extra, connection)
        return
    ops.verify_identity(record, path)
    if operation in ("cleanup-ready", "idle-ready"):
        # Dry-run only: do not persist a seal before policy and owner checks.
        if operation == "idle-ready":
            ops.require(len(extra) <= 1, "at most one idle window is accepted")
            ops.idle_policy.owner_clear(connection, str(path))
            ops.idle_policy.require_elapsed(record, ops.boot_id(), int(extra[0]) if extra else ops.idle_policy.IDLE_SECONDS)
            ops.idle_quiescence(record)
        ops.seal(record)
        return
    ops.require(record["state"] in ("created", "running"), "worktree cannot be reused")
    if record["launches"]:
        ops.drain(record["launches"][-1])


def seal_observed(ops, connection, path: Path, operation: str, extra: list[str]) -> None:
    # Release even the read snapshot before slow reconciliation/census work.
    # In rollback-journal mode a retained reader can also delay other writers.
    connection.execute("BEGIN")
    original = ops.load(connection, str(path))
    connection.execute("COMMIT")
    observed = copy.deepcopy(original)
    ops.mutate_record(observed, path, operation, extra, connection)

    connection.execute("BEGIN IMMEDIATE")
    ops.initialize(connection)
    current = ops.load(connection, str(path))
    ops.require(current.get("generation") == original.get("generation"), "worktree generation changed during observation")
    if current.get("manager") == ops.owner_lifetime.MANAGER:
        ops.owner_lifetime.require_admission_observed(current)
    # Also reject changes to leases, idle policy, archive state or launch history;
    # never overwrite a concurrent mutation with an older observation snapshot.
    ops.require(current == original, "lifetime changed during observation; retry sealing")
    ops.verify_identity(current, path)
    if operation == "seal-idle":
        ops.idle_policy.owner_clear(connection, str(path))
        ops.idle_policy.require_elapsed(current, ops.boot_id(), int(extra[0]) if extra else ops.idle_policy.IDLE_SECONDS)
    ops.save(connection, observed)
    connection.execute("COMMIT")
