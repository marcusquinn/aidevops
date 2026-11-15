"""Terminal retirement lock sweep and shared retirement event identifiers."""

from __future__ import annotations

import fcntl
import os
from pathlib import Path
import sqlite3
import stat
from typing import Any
from uuid import UUID, uuid5

LOCK_SWEEP_LIMIT = 500


def event_id(generation: str, phase: str) -> str:
    return str(uuid5(UUID(generation), f"retirement-{phase}"))


def _identity(path: Path) -> list[int]:
    info = path.lstat()
    return [info.st_dev, info.st_ino]


def lock_is_named(descriptor: int, path: Path) -> bool:
    """True if the open descriptor is an empty private regular file still at path."""
    info = os.fstat(descriptor)
    try:
        named = _identity(path) == [info.st_dev, info.st_ino]
    except OSError:
        return False
    return (stat.S_ISREG(info.st_mode) and info.st_nlink == 1
            and info.st_size == 0 and named)


def lock_exclusive_named(descriptor: int, path: Path) -> bool:
    """Take the exclusive lock only on a still-named lock file; False if invalid.

    A terminal-lock sweep may unlink the file between open and flock; the holder
    must own the file that is still named, or it would not exclude.
    """
    if not lock_is_named(descriptor, path):
        return False
    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    return lock_is_named(descriptor, path)


def terminal_lock_generation(name: str) -> str | None:
    """Return the canonical generation of a `retirement-<uuid>.lock` name."""
    if not (name.startswith("retirement-") and name.endswith(".lock")):
        return None
    try:
        generation = UUID(name[len("retirement-"):-len(".lock")])
    except ValueError:
        return None
    return str(generation) if name == f"retirement-{generation}.lock" else None


def unlink_free_lock(path: Path) -> bool:
    """Unlink a lock only while holding it, on the inode that is still named."""
    try:
        descriptor = os.open(path, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return False
    try:
        if not lock_is_named(descriptor, path):
            return False
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if not lock_is_named(descriptor, path):
            return False
        path.unlink()
        return True
    except OSError:
        return False
    finally:
        os.close(descriptor)


def _is_retired(connection: sqlite3.Connection, generation: str) -> bool:
    try:
        row = connection.execute(
            "SELECT 1 FROM events WHERE event_id=?",
            (event_id(generation, "retired"),),
        ).fetchone()
    except Exception:  # unreadable state: never unlink
        return False
    return row is not None


def sweep_retirement_locks(
    store: Any, connection: sqlite3.Connection, *, limit: int = LOCK_SWEEP_LIMIT,
) -> dict[str, int]:
    """Remove locks of terminally retired generations; refuse on any doubt.

    Active or unknown generations are skipped untouched; only held or
    unremovable terminal locks count as refused. At most `limit` locks are tried.
    """
    counts = {"removed": 0, "refused": 0}
    try:
        names = sorted(entry.name for entry in os.scandir(store.directory))
    except OSError:
        return counts
    for name in names:
        if counts["removed"] + counts["refused"] >= limit:
            break
        generation = terminal_lock_generation(name)
        if generation is None or not _is_retired(connection, generation):
            continue
        outcome = "removed" if unlink_free_lock(store.directory / name) else "refused"
        counts[outcome] += 1
    return counts
