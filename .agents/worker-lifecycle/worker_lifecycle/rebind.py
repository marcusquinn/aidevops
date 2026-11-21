"""Re-bind a same-installation worktree whose canonical checkout moved on disk.

Only the marker's `git_directory` path string may differ. Every physical proof
must still hold: installation, worktree path, both inodes, the registry's
generation at that path, and Git's own `gitdir` backlink. A copy or restore has
new inodes (or a stale backlink), so it keeps refusing. The operation is
journaled, idempotent and never an admission or removal right.
"""

from __future__ import annotations

import os
from pathlib import Path
import sqlite3
from uuid import UUID, uuid4, uuid5

from .admission import AdmissionRegistry
from .directory_handle import DirectoryHandle
from .enrollment import MARKER, _directory_inode, _git_directory, _read_marker
from .storage import LifecycleRegistry, StoreConflict, encode

__all__ = ["rebind_moved_admin"]

MISMATCH = "generation-directory-mismatch"


def _replace_marker(directory: Path, value: dict) -> None:
    temporary = directory / f".aidevops-generation-{uuid4()}.tmp"
    descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(encode(value).encode("utf-8"))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, directory / MARKER)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def _require_registered(connection: sqlite3.Connection, generation: str, path: Path) -> None:
    row = connection.execute(
        "SELECT path,state FROM generation_admissions WHERE generation_id=?", (generation,),
    ).fetchone()
    if row is None or row["path"] != str(path) or row["state"] not in ("open", "closed"):
        raise StoreConflict(MISMATCH)


def _commit_rebind(store: LifecycleRegistry, path: Path, directory: Path, value: dict) -> dict:
    generation = value["generation_id"]
    previous, current = value["git_directory"], str(directory)
    with store.connection(write=True) as connection:
        _require_registered(connection, generation, path)
        store._event(connection, str(uuid5(UUID(generation), "rebind:" + current)), {
            "type": "rebind-admin-directory", "generation_id": generation,
            "path": str(path), "from": previous, "to": current,
        })
        # Replace under the write transaction; replay repairs a crash before this.
        _replace_marker(directory, dict(value, git_directory=current))
    return {"generation_id": generation, "rebound": True, "from": previous,
            "to": current, "cleanup_authorized": False}


def rebind_moved_admin(store: LifecycleRegistry, path: Path) -> dict:
    with store.connection() as connection:
        AdmissionRegistry._require_schema(connection)
    with DirectoryHandle(path) as root:
        directory = _git_directory(path)  # also proves the gitdir backlink
        with DirectoryHandle(directory) as admin:
            value = _read_marker(directory / MARKER)
            expected = {
                "format": 2, "installation_id": store.installation_id(),
                "path": str(path), "directory": _directory_inode(path),
                "git_directory": value.get("git_directory"),
                "git_identity": _directory_inode(directory),
            }
            comparable = {name: item for name, item in value.items() if name != "generation_id"}
            valid = (encode(comparable) == encode(expected) and isinstance(value["git_directory"], str)
                     and root.matches_path() and admin.matches_path())
            if not valid:
                raise StoreConflict(MISMATCH)
            if value["git_directory"] == str(directory):
                return {"generation_id": value["generation_id"], "rebound": False,
                        "cleanup_authorized": False}
            return _commit_rebind(store, path, directory, value)
