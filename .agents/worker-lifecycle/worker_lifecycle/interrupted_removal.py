"""Resume a journaled native worktree removal that started but did not finish.

`git worktree remove --force` deletes files before its administration entry. A
timeout or a killed pass leaves a partially deleted private tree whose content
snapshot can never match the pre-removal receipt again (GH#37326). Removal
authority was established for this exact tree when the journal recorded that
removal began. A resume still re-checks identity and the idle process census in
its caller, then requires deletion-only evidence from this module: no
Git-visible path that still exists changed after removal began. Ignored files
follow the git-only capture policy and are never evidence.
"""

from __future__ import annotations

from collections.abc import Callable
from datetime import datetime
from pathlib import Path
import sqlite3

from .storage import StoreConflict

# Native removal of a multi-GB tree outlives ordinary helper calls (GH#37326).
REMOVAL_TIMEOUT = 300


def native_timeout(arguments: tuple[str, ...]) -> int | None:
    """Give `git ... worktree remove` its own limit; other calls keep the default."""
    return REMOVAL_TIMEOUT if tuple(arguments[2:4]) == ("worktree", "remove") else None


def resume_first(rows: list[dict], journaled: Callable[[str], bool]) -> list[dict]:
    """Move one interrupted native removal ahead of the cleanup rotation.

    Its relocated tree still holds a registered worktree slot and its disk until
    the rotation returns, which can take days. One per pass keeps a persistently
    failing resume from starving the rotation; the `resume` flag tells the caller
    not to move its cursor.
    """
    for index, row in enumerate(rows):
        if row["state"] == "closed" and journaled(row["generation_id"]):
            return [dict(row, resume=True), *rows[:index], *rows[index + 1:]]
    return rows


def require_removable(
    target: Path, started: int | None, unchanged: Callable[[], bool],
    git: Callable[..., str],
) -> None:
    """Authorize native removal of a private tree, first attempt or resumed.

    Before removal begins the exact pre-removal snapshot must still match. Once
    the journal records the start, that snapshot already authorized removal and
    only deletions may have followed it.
    """
    if started is not None:
        require_deletion_only(target, started, git)
    elif not unchanged():
        raise StoreConflict("private-worktree-changed")


def removal_started(connection: sqlite3.Connection, event_id: str) -> int | None:
    """Return when the journal recorded removal start, in nanoseconds, or None."""
    row = connection.execute(
        "SELECT recorded_at FROM events WHERE event_id=?", (event_id,),
    ).fetchone()
    if row is None:
        return None
    moment = datetime.fromisoformat(str(row[0]).replace("Z", "+00:00"))
    if moment.tzinfo is None:
        raise ValueError("interrupted-removal-time-unavailable")
    # Millisecond truncation can only move the start earlier: fail closed.
    return int(moment.timestamp() * 1000) * 1_000_000


def require_deletion_only(
    target: Path, started: int, git: Callable[..., str],
) -> None:
    """Fail closed unless every remaining Git-visible path predates removal start.

    Inode change time also moves on rename, chmod, link and copy-with-times,
    so restored or replaced content cannot hide behind an old modification time.
    """
    listed = git("-C", str(target), "ls-files", "-z", "--cached", "--others",
                 "--exclude-standard")
    for name in filter(None, listed.split("\0")):
        try:
            info = (target / name).lstat()
        except FileNotFoundError:
            continue  # Deleted by the interrupted removal; the archive keeps it.
        if info.st_ctime_ns > started:
            raise ValueError("interrupted-removal-content-changed")
