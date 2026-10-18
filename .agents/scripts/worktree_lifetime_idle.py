#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Boot-scoped idle evidence in the existing managed worktree registry."""

import copy
import math
import os
import time


IDLE_SECONDS = 24 * 60 * 60


def initialize(connection):
    # Fixed SQL identifiers, never caller-supplied. Any ownership mutation resets
    # the interval, including an ABA reclaim returning to an identical owner row.
    for event, paths in (("INSERT", "NEW.worktree_path"),
                         ("UPDATE", "OLD.worktree_path, NEW.worktree_path"),
                         ("DELETE", "OLD.worktree_path")):
        connection.execute(f"DROP TRIGGER IF EXISTS managed_idle_reset_{event.lower()}")
        connection.execute(f"""CREATE TRIGGER IF NOT EXISTS managed_idle_reset_{event.lower()}
            AFTER {event} ON worktree_owners
            BEGIN UPDATE worktree_managed_lifetimes
                SET record = json_set(json_remove(record, '$.idle'), '$.ownership_epoch',
                    COALESCE(json_extract(record, '$.ownership_epoch'), 0) + 1)
                WHERE path IN ({paths});
            END""")


def invalidate(record):
    record.pop("idle", None)
    record["ownership_epoch"] = record.get("ownership_epoch", 0) + 1


def owner_clear(connection, path):
    row = connection.execute("SELECT owner_pid FROM worktree_owners WHERE worktree_path = ?", (path,)).fetchone()
    if row is None:
        return
    pid = row[0]
    if not isinstance(pid, int) or pid <= 0:
        raise ValueError("owner identity unavailable")
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return
    # Permission/access errors propagate: unavailable is not dead.
    raise ValueError("worktree owner remains alive")


def timestamp_valid(value, now):
    return type(value) in (int, float) and math.isfinite(value) and 0 <= value <= now


def interval_valid(record, boot, wall, monotonic):
    idle = record.get("idle", {})
    if not isinstance(idle, dict) or not record.get("generation"):
        return False
    return all((idle.get("policy") == 1,
                idle.get("boot_id") == boot,
                idle.get("generation") == record["generation"],
                idle.get("ownership_epoch") == record.get("ownership_epoch", 0),
                timestamp_valid(idle.get("since"), wall),
                timestamp_valid(idle.get("monotonic_since"), monotonic)))


def quiescence(record, boot_id, drain, seal):
    # Revalidate even a previously sealed record; old receipts alone must not
    # establish a fresh idle interval after reboot or unit replacement.
    for launch in record["launches"]:
        if launch["boot_id"] != boot_id():
            raise ValueError("idle boot generation unavailable")
        if launch["invocation"] is not None:
            drain(launch)
        elif launch.get("admission_cancelled") is not True:
            raise ValueError("unresolved admission")
    seal(record)


def observe(connection, record, boot, seal):
    owner_clear(connection, record["identity"]["path"])
    if record["state"] not in ("created", "running", "sealed"):
        raise ValueError("pending admission is not confirmed idle")
    # Establish current quiescence, without persisting a seal or cancelling work.
    seal(copy.deepcopy(record))
    wall, monotonic = time.time(), time.monotonic()
    if not interval_valid(record, boot, wall, monotonic):
        record["idle"] = {"policy": 1, "since": wall, "monotonic_since": monotonic,
                          "boot_id": boot, "generation": record["generation"],
                          "ownership_epoch": record.get("ownership_epoch", 0)}
    record["idle"].update(observed_at=wall, source="managed-lifetime-quiescence")


def require_elapsed(record, boot, minimum=IDLE_SECONDS):
    if type(minimum) is not int or minimum < IDLE_SECONDS:
        raise ValueError("idle window must be at least 86400 seconds")
    wall, monotonic = time.time(), time.monotonic()
    if not interval_valid(record, boot, wall, monotonic):
        raise ValueError("confirmed idle evidence unavailable")
    idle = record["idle"]
    # A forward wall-clock jump cannot accelerate expiry; a backward jump cannot
    # turn unknown time into eligibility. Sleep may conservatively extend the wait.
    if min(wall - idle["since"], monotonic - idle["monotonic_since"]) < minimum:
        raise ValueError(f"confirmed idle window incomplete ({minimum}s required)")
