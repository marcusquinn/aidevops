"""Durable path-and-generation reservation for foreign-worktree retirement (GH#37828).

Event rows can be compacted, so the fence lives in its own table, created lazily
inside a write transaction (same precedent as `archived_event_ids`; no schema
bump). `reserve` and the registration writers all run under `BEGIN IMMEDIATE`,
so exactly one wins: a writer that commits first makes `reserve` refuse; a
reservation that commits first makes every writer refuse. Both generation and
path stay fenced after completion: a delayed writer may have validated the path
before retirement, even if a replacement directory now exists there. Safe path
reuse requires a separate incarnation-aware protocol; existence is not enough.
"""

from __future__ import annotations

import sqlite3

from .storage import StoreConflict

_TABLE = "retirement_fences"


def _exists(connection: sqlite3.Connection) -> bool:
    return connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (_TABLE,),
    ).fetchone() is not None


def require_unfenced(connection: sqlite3.Connection, generation_id: str, path: str) -> None:
    """Refuse a writer naming any retired/reserved generation or path."""
    if _exists(connection) and connection.execute(
        "SELECT 1 FROM retirement_fences WHERE generation_id=? OR path=?",
        (generation_id, path),
    ).fetchone():
        raise StoreConflict("generation-retirement-reserved")


def reserve(connection: sqlite3.Connection, generation_id: str, path: str) -> None:
    """Atomically verify absence of registration, then fence; idempotent on resume."""
    if not _exists(connection):
        connection.execute(
            "CREATE TABLE retirement_fences (generation_id TEXT PRIMARY KEY, path TEXT NOT NULL, "
            "state TEXT NOT NULL CHECK(state IN ('active','released')))")
    existing = connection.execute(
        "SELECT path FROM retirement_fences WHERE generation_id=?", (generation_id,),
    ).fetchone()
    if existing is not None:
        if existing["path"] != path:
            raise StoreConflict("retirement-fence-path-conflict")
        return
    other = connection.execute(
        "SELECT 1 FROM retirement_fences WHERE path=?", (path,),
    ).fetchone()
    registered = (
        connection.execute("SELECT 1 FROM generations WHERE generation_id=? OR path=?",
                           (generation_id, path)).fetchone()
        or connection.execute("SELECT 1 FROM generation_admissions WHERE generation_id=? OR path=?",
                              (generation_id, path)).fetchone()
        or connection.execute("SELECT 1 FROM bindings WHERE generation_id=?",
                              (generation_id,)).fetchone()
    )
    if other is not None or registered is not None:
        raise StoreConflict("foreign-generation-registered")
    connection.execute("INSERT INTO retirement_fences VALUES (?,?,'active')", (generation_id, path))


def release_path(connection: sqlite3.Connection, generation_id: str) -> None:
    """Record completion; legacy 'released' rows remain path tombstones for writers."""
    if _exists(connection):
        connection.execute("UPDATE retirement_fences SET state='released' WHERE generation_id=?",
                           (generation_id,))
