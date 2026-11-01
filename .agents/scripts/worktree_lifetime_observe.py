# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Seal without holding SQLite locks during slow observation (callers inject managed-lifetime ops)."""

import copy
from pathlib import Path


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
