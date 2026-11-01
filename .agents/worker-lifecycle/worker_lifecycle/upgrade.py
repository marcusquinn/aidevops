"""Coordinated schema upgrade backup; never infer admission from old bindings."""

from contextlib import closing
import os
from pathlib import Path
import sqlite3
import sys
import time
from uuid import uuid4

from .storage import APPLICATION_ID, LifecycleRegistry, StoreConflict, _private


def upgrade_registry(store: LifecycleRegistry, backup_dir: Path | None = None) -> dict:
    """Shared automatic/manual entry; schema-2 clients need no worker drain."""
    with store.connection() as connection:
        schema = connection.execute("PRAGMA user_version").fetchone()[0]
    if schema == 2:
        return {"status": "already-current", "schema_version": 2,
                "backup_dir": None, "cleanup_authorized": False}
    directory = backup_dir or store.directory / f"schema-1-backup-{uuid4()}"
    upgraded = store.upgrade_schema(backup_dir=directory)
    if upgraded:
        print("[worker-lifecycle] schema-upgraded from=1 to=2 backup=verified", file=sys.stderr)
    return {"status": "upgraded" if upgraded else "already-current", "schema_version": 2,
            "backup_dir": str(directory.absolute()) if upgraded else None,
            "cleanup_authorized": False}


def _sync(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def backup_before_upgrade(
    store: LifecycleRegistry, locked: sqlite3.Connection, directory: Path,
) -> None:
    """Back up committed WAL state while the caller holds BEGIN IMMEDIATE.

    A separate reader avoids backing up from a connection with a write transaction.
    The writer lock spans backup verification and migration; live runs are retained.
    Failed backup artifacts are retained, never reused or silently overwritten.
    """
    directory = directory.absolute()
    if directory.parent.resolve(strict=True) != directory.parent:
        raise StoreConflict("backup-parent-must-be-canonical")
    _private(directory.parent, directory=True)
    directory.mkdir(mode=0o700)
    destination = directory / "registry.sqlite3"
    descriptor = os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(descriptor)
    deadline = time.monotonic() + 30

    def progress(_status: int, _remaining: int, _total: int) -> None:
        if time.monotonic() >= deadline:
            raise StoreConflict("upgrade-backup-timeout")

    with closing(store._connect()) as source, closing(sqlite3.connect(destination)) as target:
        source.backup(target, pages=256, progress=progress)
        verified = (
            target.execute("PRAGMA integrity_check").fetchall() == [("ok",)],
            not target.execute("PRAGMA foreign_key_check").fetchall(),
            target.execute("PRAGMA application_id").fetchone()[0] == APPLICATION_ID,
            target.execute("PRAGMA user_version").fetchone()[0] == 1,
            target.execute("SELECT installation_id FROM metadata").fetchone()[0]
            == locked.execute("SELECT installation_id FROM metadata").fetchone()[0],
        )
        if not all(verified):
            raise StoreConflict("upgrade-backup-verification-failed")
        # Make the backup a standalone database, without a required WAL sidecar.
        if target.execute("PRAGMA journal_mode=DELETE").fetchone()[0] != "delete":
            raise StoreConflict("upgrade-backup-journal-mode")
    _private(destination)
    _sync(destination)
    _sync(directory)
    _sync(directory.parent)
