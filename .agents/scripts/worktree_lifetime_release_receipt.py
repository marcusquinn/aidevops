#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Durable release receipts for retained aidevops-worker-* units (GH#39702).

worktree_lifetime_release.py commits a receipt after a drained sample of one
invocation and before it stops the unit. Stopping destroys the invocation's
cgroup, so it cannot be repopulated: the recorded sample then stands in for the
retained unit, like an ended-boot receipt stands in for a previous boot.
"""

from contextlib import closing
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import time

import worktree_lifetime_owner as owner

RELEASE_TABLE = "worktree_unit_releases"
RELEASE_SCHEMA = "unit-release/v1"
UNIT_NAME = re.compile(r"aidevops-worker-[A-Za-z0-9_-]+(?:\.service)?")
READ_ERRORS = (OSError, ValueError, KeyError, TypeError, sqlite3.Error, subprocess.SubprocessError)


def unit_id(unit):
    """Canonical unit name: Pulse records omit the .service suffix."""
    return unit if unit.endswith(".service") else unit + ".service"


def registry_db():
    directory = Path(os.environ.get("WORKTREE_REGISTRY_DIR") or Path.home() / ".aidevops/.agent-workspace")
    return Path(os.environ.get("WORKTREE_REGISTRY_DB") or directory / "worktree-registry.db")


def connect(db, readonly):
    owner.require(db.is_file() and not db.is_symlink(), "registry unavailable")
    uri = db.resolve().as_uri() + ("?mode=ro" if readonly else "?mode=rw")
    return sqlite3.connect(uri, uri=True, timeout=10, isolation_level=None)


def initialize(connection):
    connection.execute("""CREATE TABLE IF NOT EXISTS worktree_unit_releases (
        unit TEXT NOT NULL, invocation TEXT NOT NULL, boot_id TEXT NOT NULL, record TEXT NOT NULL,
        PRIMARY KEY(unit, invocation))""")


def unit_presence(unit):
    """LoadState and InvocationID only: a released unit is no longer loaded."""
    owner.require(UNIT_NAME.fullmatch(unit) is not None, "invalid worker unit")
    output = subprocess.check_output(  # nosec B603 - fixed argv, validated unit name
        ["systemctl", "--user", "show", unit, "--property=LoadState", "--property=InvocationID"],
        text=True, stderr=subprocess.DEVNULL, timeout=10).strip()
    return dict(line.split("=", 1) for line in output.splitlines() if "=" in line)


def read(unit, invocation):
    """Return the persisted receipt for one invocation, or None when absent."""
    db = registry_db()
    if not db.is_file() or db.is_symlink():
        return None
    with closing(connect(db, readonly=True)) as connection:
        if connection.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
                              (RELEASE_TABLE,)).fetchone() is None:
            return None
        row = connection.execute("SELECT record FROM worktree_unit_releases WHERE unit=? AND invocation=?",
                                 (unit_id(unit), invocation)).fetchone()
    return json.loads(row[0]) if row else None


def commit(db, unit, sample, current_boot, referenced):
    receipt = {"schema": RELEASE_SCHEMA, "unit": unit, "InvocationID": sample["InvocationID"],
               "boot_id": current_boot, "requested_at": time.time(), "quiescence": sample,
               "referenced": referenced}
    with closing(connect(db, readonly=False)) as connection:
        connection.execute("BEGIN IMMEDIATE")
        initialize(connection)
        connection.execute("INSERT OR IGNORE INTO worktree_unit_releases VALUES (?, ?, ?, ?)",
                           (unit, sample["InvocationID"], current_boot, json.dumps(receipt, sort_keys=True)))
        connection.execute("COMMIT")


def prune(db, current_boot):
    """Drop receipts from earlier boots: ended-boot receipts replace them."""
    with closing(connect(db, readonly=False)) as connection:
        connection.execute("BEGIN IMMEDIATE")
        initialize(connection)
        pruned = connection.execute("DELETE FROM worktree_unit_releases WHERE boot_id != ?", (current_boot,)).rowcount
        connection.execute("COMMIT")
    return pruned


def valid(launch, receipt):
    """Validate a same-boot unit release receipt for one bound launch."""
    if not isinstance(receipt, dict) or not isinstance(launch.get("unit"), str):
        return False
    requested_at = receipt.get("requested_at")
    return all((receipt.get("schema") == RELEASE_SCHEMA,
                owner.valid_invocation(launch.get("invocation")),
                receipt.get("InvocationID") == launch.get("invocation"),
                receipt.get("unit") == unit_id(launch["unit"]),
                owner.valid_boot_id(launch.get("boot_id")),
                receipt.get("boot_id") == launch.get("boot_id"),
                owner.drained_snapshot_valid(receipt.get("quiescence"), launch.get("invocation")),
                type(requested_at) in (int, float)
                and math.isfinite(requested_at)
                and 0 < requested_at <= time.time()))


def drain_released(launch, current_boot, boot_reader, presence_reader=None, release_reader=None):
    """Record quiescence from a release receipt once its unit is gone; fail closed."""
    try:
        if (presence_reader or unit_presence)(launch["unit"]).get("LoadState") != "not-found":
            return False
        receipt = (release_reader or read)(launch["unit"], launch["invocation"])
        if not valid(launch, receipt) or boot_reader() != current_boot:
            return False
    except READ_ERRORS:
        return False
    launch["quiescence"] = dict(receipt["quiescence"])
    return True
