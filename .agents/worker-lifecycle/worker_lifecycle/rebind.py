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
        descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def _require_registered(connection: sqlite3.Connection, generation: str, path: Path) -> None:
    row = connection.execute(
        "SELECT path,state FROM generation_admissions WHERE generation_id=?", (generation,),
    ).fetchone()
    if row is None or row["path"] != str(path) or row["state"] not in ("open", "closed"):
        raise StoreConflict(MISMATCH)


def _require_unchanged(path: Path, directory: Path, root: DirectoryHandle, admin: DirectoryHandle) -> None:
    if not root.matches_path() or not admin.matches_path() or _git_directory(path) != directory:
        raise StoreConflict(MISMATCH)


def _commit_rebind(
    store: LifecycleRegistry, path: Path, directory: Path, value: dict,
    root: DirectoryHandle, admin: DirectoryHandle,
) -> dict:
    generation = value["generation_id"]
    previous = value.get("rebind_from", value["git_directory"])
    current = value["git_directory"] if "rebind_from" in value else str(directory)
    transition = encode([previous, current])
    # Persist a fresh identity per move, including repeat visits. Legacy pending
    # markers retain their original deterministic ID so their event can replay.
    event_id = value.get("rebind_event_id") or (
        str(uuid5(UUID(generation), "rebind:" + transition)) if "rebind_from" in value else str(uuid4())
    )
    clean = {name: item for name, item in value.items()
             if name not in ("rebind_from", "rebind_event_id")}
    pending = dict(clean, git_directory=current, rebind_from=previous, rebind_event_id=event_id)
    with store.connection(write=True) as connection:
        _require_unchanged(path, directory, root, admin)
        _require_registered(connection, generation, path)
        if _read_marker(directory / MARKER) != value:
            raise StoreConflict(MISMATCH)
        # Publish a durable recovery record with the new path before committing
        # its event. Normal enrollment rejects the extra field until finalized.
        # A crash/commit failure leaves the source path available for replay,
        # even when git_directory already names the destination.
        _replace_marker(directory, pending)
        store._event(connection, event_id, {
            "type": "rebind-admin-directory", "generation_id": generation,
            "path": str(path), "from": previous, "to": current,
        })
        _require_unchanged(path, directory, root, admin)
    # Only a committed event permits removing the recovery field. A crash here
    # replays the identical event before finalizing the marker.
    with store.connection(write=True) as connection:
        _require_unchanged(path, directory, root, admin)
        _require_registered(connection, generation, path)
        if _read_marker(directory / MARKER) != pending:
            raise StoreConflict(MISMATCH)
        _replace_marker(directory, dict(clean, git_directory=current))
    return {"generation_id": generation, "rebound": True, "from": previous,
            "to": current, "cleanup_authorized": False}


def _marker_is_valid(store: LifecycleRegistry, path: Path, directory: Path, value: dict) -> bool:
    expected = {
        "format": 2, "installation_id": store.installation_id(),
        "path": str(path), "directory": _directory_inode(path),
        "git_directory": value.get("git_directory"),
        "git_identity": _directory_inode(directory),
    }
    comparable = {name: item for name, item in value.items()
                  if name not in ("generation_id", "rebind_from", "rebind_event_id")}
    if encode(comparable) != encode(expected) or not isinstance(value["git_directory"], str):
        return False
    if "rebind_from" not in value:
        return "rebind_event_id" not in value
    return isinstance(value["rebind_from"], str)


def rebind_moved_admin(store: LifecycleRegistry, path: Path) -> dict:
    with store.connection() as connection:
        AdmissionRegistry._require_schema(connection)
    with DirectoryHandle(path) as root:
        directory = _git_directory(path)  # also proves the gitdir backlink
        with DirectoryHandle(directory) as admin:
            value = _read_marker(directory / MARKER)
            valid = (_marker_is_valid(store, path, directory, value)
                     and root.matches_path() and admin.matches_path())
            if not valid:
                raise StoreConflict(MISMATCH)
            with store.connection() as connection:
                _require_registered(connection, value["generation_id"], path)
            if "rebind_from" in value:
                # Finish the recorded transition even after another move. Only
                # then start a separate transition to today's proven admin path.
                result = _commit_rebind(store, path, directory, value, root, admin)
                if value["git_directory"] == str(directory):
                    return result
                value = _read_marker(directory / MARKER)
            if value["git_directory"] == str(directory) and "rebind_from" not in value:
                return {"generation_id": value["generation_id"], "rebound": False,
                        "cleanup_authorized": False}
            return _commit_rebind(store, path, directory, value, root, admin)
