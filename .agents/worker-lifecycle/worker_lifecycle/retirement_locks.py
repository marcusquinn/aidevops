"""Terminal retirement lock sweep and shared retirement event identifiers."""

from __future__ import annotations

import fcntl
import os
from pathlib import Path
import stat
from uuid import UUID, uuid5

LOCK_SWEEP_LIMIT = 500


def event_id(generation: str, phase: str) -> str:
    return str(uuid5(UUID(generation), f"retirement-{phase}"))


def _identity(path: Path) -> list[int]:
    info = path.lstat()
    return [info.st_dev, info.st_ino]


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
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                or info.st_size != 0):
            return False
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if _identity(path) != [info.st_dev, info.st_ino]:
            return False
        path.unlink()
        return True
    except OSError:
        return False
    finally:
        os.close(descriptor)


def _is_retired(connection, generation: str) -> bool:
    try:
        row = connection.execute(
            "SELECT 1 FROM events WHERE event_id=?",
            (event_id(generation, "retired"),),
        ).fetchone()
    except Exception:  # unreadable state: never unlink
        return False
    return row is not None


def sweep_retirement_locks(
    store, connection, *, limit: int = LOCK_SWEEP_LIMIT,
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
