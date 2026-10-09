# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Atomic schema initialization for local GitHub transport state."""

from __future__ import annotations

import sqlite3
import time


SCHEMA_VERSION = 2
WAL_SWITCH_TIMEOUT_SECONDS = 10.0
SCHEMA_STATEMENTS = (
    """CREATE TABLE IF NOT EXISTS quota (
        scope TEXT NOT NULL, resource TEXT NOT NULL,
        remaining INTEGER NOT NULL, reset REAL NOT NULL,
        observed REAL NOT NULL, blocked_until REAL NOT NULL DEFAULT 0,
        quota_limit INTEGER NOT NULL,
        PRIMARY KEY(scope, resource))""",
    """CREATE TABLE IF NOT EXISTS reservation (
        id TEXT PRIMARY KEY, scope TEXT NOT NULL, resource TEXT NOT NULL,
        started REAL NOT NULL, pid INTEGER NOT NULL,
        birth TEXT NOT NULL, credential TEXT NOT NULL,
        uncertain INTEGER NOT NULL DEFAULT 0)""",
    "CREATE TABLE IF NOT EXISTS binding (credential TEXT PRIMARY KEY, scope TEXT NOT NULL)",
    "CREATE TABLE IF NOT EXISTS alias (scope TEXT PRIMARY KEY, target TEXT NOT NULL)",
    """CREATE TABLE IF NOT EXISTS revalidation (
        scope TEXT NOT NULL, resource TEXT NOT NULL, started REAL NOT NULL,
        reservation_id TEXT NOT NULL,
        PRIMARY KEY(scope, resource))""",
    """CREATE TABLE IF NOT EXISTS admission_history (
        scope TEXT NOT NULL, resource TEXT NOT NULL, started REAL NOT NULL)""",
    "CREATE INDEX IF NOT EXISTS admission_history_scope ON admission_history(scope, resource, started)",
    """CREATE TABLE IF NOT EXISTS pacing (
        scope TEXT NOT NULL, resource TEXT NOT NULL, reset REAL NOT NULL,
        retry_at REAL NOT NULL, remaining INTEGER NOT NULL,
        PRIMARY KEY(scope, resource))""",
    """CREATE TABLE IF NOT EXISTS reconciliation (
        source TEXT PRIMARY KEY, owner TEXT NOT NULL, reconciled REAL NOT NULL)""",
)


def _enable_wal(db: sqlite3.Connection) -> str:
    """Switch to WAL, retrying lock contention within a bounded deadline.

    Some SQLite builds (for example macOS system Python 3.9) return
    "database is locked" for a concurrent rollback-to-WAL switch without
    consulting the busy handler, so concurrent legacy opens must retry here.
    """
    deadline = time.monotonic() + WAL_SWITCH_TIMEOUT_SECONDS
    delay = 0.005
    while True:
        try:
            return db.execute("PRAGMA journal_mode=WAL").fetchone()[0]
        except sqlite3.OperationalError as error:
            message = str(error).lower()
            if "locked" not in message and "busy" not in message:
                raise
            if time.monotonic() >= deadline:
                raise
        time.sleep(delay)
        delay = min(delay * 2, 0.1)


def ensure_schema(db: sqlite3.Connection) -> None:
    """Initialize or migrate schema once under a bounded write lock."""
    version = db.execute("PRAGMA user_version").fetchone()[0]
    if version == SCHEMA_VERSION:
        return

    db.execute("PRAGMA busy_timeout=10000")
    try:
        if version < 2:
            journal_mode = _enable_wal(db)
            if str(journal_mode).lower() != "wal":
                raise sqlite3.OperationalError("failed to enable WAL journal mode")
        db.execute("BEGIN IMMEDIATE")
        version = db.execute("PRAGMA user_version").fetchone()[0]
        if version < SCHEMA_VERSION:
            for statement in SCHEMA_STATEMENTS:
                db.execute(statement)
            db.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
        elif version > SCHEMA_VERSION:
            raise ValueError("transport state schema is newer than this runtime")
        db.execute("COMMIT")
    except BaseException:
        db.rollback()
        raise
    finally:
        db.execute("PRAGMA busy_timeout=5000")
