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

# Binding recency (GH#38619). A separate table keeps the positional
# `INSERT OR REPLACE INTO binding VALUES(?,?)` of older runtime bundles valid,
# and the trigger stamps every binding write from any bundle inside the writer's
# own transaction. user_version is unchanged, so older bundles keep working.
# One core window plus the maximum reservation age: a credential not bound for
# longer cannot own a stored reset which is still in the future.
BINDING_RECENCY_SECONDS = 3600 + 180
BINDING_SEEN_TRIGGER = "binding_seen_stamp"
_BINDING_SEEN_TABLE = (
    "CREATE TABLE IF NOT EXISTS binding_seen (credential TEXT PRIMARY KEY, last_seen REAL NOT NULL)"
)
_BINDING_SEEN_STAMP = (
    f"CREATE TRIGGER IF NOT EXISTS {BINDING_SEEN_TRIGGER} AFTER INSERT ON binding BEGIN "
    "INSERT OR REPLACE INTO binding_seen VALUES("
    "NEW.credential, (julianday('now') - 2440587.5) * 86400.0); END"
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


def ensure_binding_recency(db: sqlite3.Connection, now: float | None = None) -> bool:
    """Idempotently add binding recency evidence; never required for admission.

    Existing bindings are backfilled as seen now, so they stay live for one
    more window before ageing out. A losing or locked racer returns False and
    leaves every binding live (conservative), never unbounded admission.
    """
    present = db.execute(
        "SELECT 1 FROM sqlite_master WHERE type='trigger' AND name=?", (BINDING_SEEN_TRIGGER,),
    ).fetchone()
    if present:
        return True
    try:
        db.execute("BEGIN IMMEDIATE")
    except sqlite3.OperationalError:
        return False
    try:
        db.execute(_BINDING_SEEN_TABLE)
        db.execute("INSERT OR IGNORE INTO binding_seen SELECT credential, ? FROM binding",
                    (time.time() if now is None else now,))
        db.execute(_BINDING_SEEN_STAMP)
        db.execute("COMMIT")
    except sqlite3.OperationalError:
        db.rollback()
        return False
    except BaseException:
        db.rollback()
        raise
    return True


def live_binding_credentials(db, scope: str, root, now: float) -> list:
    """Credentials bound to scope which may still own live quota evidence.

    A binding is live when it was seen inside BINDING_RECENCY_SECONDS, when its
    credential holds any reservation (live or uncertain debt), or when it has no
    recency evidence at all (older writer or failed migration): unknown stays
    conservative and is never treated as retired.
    """
    try:
        rows = db.execute(
            "SELECT b.credential,b.scope FROM binding b "
            "LEFT JOIN binding_seen s ON s.credential=b.credential "
            "WHERE s.last_seen IS NULL OR s.last_seen>=? "
            "OR EXISTS(SELECT 1 FROM reservation r WHERE r.credential=b.credential)",
            (now - BINDING_RECENCY_SECONDS,),
        ).fetchall()
    except sqlite3.OperationalError:
        rows = db.execute("SELECT credential,scope FROM binding").fetchall()
    return [credential for credential, bound in rows if root(bound) == scope]


def ensure_schema(db: sqlite3.Connection) -> None:
    """Initialize or migrate schema once under a bounded write lock."""
    _ensure_versioned_schema(db)
    ensure_binding_recency(db)


def _ensure_versioned_schema(db: sqlite3.Connection) -> None:
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
