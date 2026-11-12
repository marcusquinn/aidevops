"""Durable path-and-generation reservation for foreign-worktree retirement (GH#37828).

Event rows can be compacted, so the fence lives in its own table, created lazily
inside a write transaction (same precedent as `archived_event_ids`; no schema
bump). `reserve` and the registration writers all run under `BEGIN IMMEDIATE`,
so exactly one wins: a writer that commits first makes `reserve` refuse; a
reservation that commits first makes every writer refuse. The generation stays
fenced forever; the path is released only when retirement completes.
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
    """Refuse a registration writer that names a fenced generation or active path."""
    if _exists(connection) and connection.execute(
        f"SELECT 1 FROM {_TABLE} WHERE generation_id=? OR (path=? AND state='active')",
        (generation_id, path),
    ).fetchone():
        raise StoreConflict("generation-retirement-reserved")


def reserve(connection: sqlite3.Connection, generation_id: str, path: str) -> None:
    """Atomically verify absence of registration, then fence; idempotent on resume."""
    if connection.execute(
        f"SELECT 1 FROM sqlite_master WHERE type='table' AND name='{_TABLE}'",
    ).fetchone() is None:
        connection.execute(
            f"CREATE TABLE {_TABLE} (generation_id TEXT PRIMARY KEY, path TEXT NOT NULL, "
            "state TEXT NOT NULL CHECK(state IN ('active','released')))")
    existing = connection.execute(
        f"SELECT path FROM {_TABLE} WHERE generation_id=?", (generation_id,),
    ).fetchone()
    if existing is not None:
        if existing["path"] != path:
            raise StoreConflict("retirement-fence-path-conflict")
        return
    other = connection.execute(
        f"SELECT 1 FROM {_TABLE} WHERE path=? AND state='active'", (path,),
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
    connection.execute(f"INSERT INTO {_TABLE} VALUES (?,?,'active')", (generation_id, path))


def release_path(connection: sqlite3.Connection, generation_id: str) -> None:
    """Free the path after verified retirement; the generation id remains fenced."""
    if _exists(connection):
        connection.execute(f"UPDATE {_TABLE} SET state='released' WHERE generation_id=?",
                           (generation_id,))
