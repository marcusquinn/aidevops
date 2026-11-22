"""Resume a journaled native worktree removal that started but did not finish.

`git worktree remove --force` deletes files before its administration entry. A
timeout or a killed pass leaves a partially deleted private tree whose content
snapshot can never match the pre-removal receipt again (GH#37326). Removal
authority was established for this exact tree when the journal recorded that
removal began. A resume still re-checks identity and the idle process census in
its caller, then requires deletion-only evidence from this module: no
Git-visible path that still exists changed after the validation boundary taken
before the final pre-removal snapshot check. Ignored files follow the git-only
capture policy and are never evidence.
"""

from __future__ import annotations

from collections.abc import Callable
from datetime import datetime
import json
import os
from pathlib import Path
import sqlite3
import time

from .storage import StoreConflict

# Native removal of a multi-GB tree outlives ordinary helper calls (GH#37326).
REMOVAL_TIMEOUT = 300
BOUNDARY = "validation_boundary_ns"
# Coarse filesystem clocks (one kernel tick) can stamp a later change early.
CLOCK_SLACK_NS = 1_000_000_000


def native_timeout(arguments: tuple[str, ...]) -> int | None:
    """Give `git ... worktree remove` its own limit; other calls keep the default."""
    return REMOVAL_TIMEOUT if tuple(arguments[2:4]) == ("worktree", "remove") else None


def resume_first(rows: list[dict], journaled: Callable[[str], bool]) -> list[dict]:
    """Move one interrupted native removal ahead of the cleanup rotation.

    Its relocated tree still holds a registered worktree slot and its disk until
    the rotation returns, which can take days. One per pass keeps resumes from
    starving the rotation; callers pass rows after quarantine and back off a
    resume that did not retire, so one failing tree cannot hold the slot. The
    `resume` flag tells the caller not to move its cursor.
    """
    for index, row in enumerate(rows):
        if row["state"] == "closed" and journaled(row["generation_id"]):
            return [dict(row, resume=True), *rows[:index], *rows[index + 1:]]
    return rows


def journaled_removals(
    connection: sqlite3.Connection, rows: list[dict],
    event_id: Callable[[str, str], str],
) -> set[str]:
    """Return closed generations whose native removal start is journaled."""
    return {row["generation_id"] for row in rows
            if row["state"] == "closed" and connection.execute(
                "SELECT 1 FROM events WHERE event_id=?",
                (event_id(row["generation_id"], "removing"),),
            ).fetchone()}


def resume_failed(row: dict, result: dict) -> bool:
    """A resume that did not retire backs off and yields the slot to the next one."""
    return bool(row.get("resume", False)) and result["status"] != "retired"


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


def validation_boundary() -> int:
    """Take before the final pre-removal snapshot check; journal with `removing`.

    The snapshot check validates only changes made before it reads the tree.
    """
    return time.time_ns() - CLOCK_SLACK_NS


def restore_git_link(target: Path, admin: Path) -> None:
    """Recreate a `.git` link that the interrupted native removal deleted.

    Git deletes the tree in directory order, then refuses a tree without `.git`.
    Callers first bind the tree and administration inodes to the plan; the
    administration backlink must still name this exact link.
    """
    link = target / ".git"
    if os.path.lexists(link):
        return
    with (admin / "gitdir").open("rb") as stream:
        backlink = stream.read(4097)
    if backlink != os.fsencode(link) + b"\n":
        raise StoreConflict("git-directory-backlink-mismatch")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    with os.fdopen(os.open(link, flags, 0o644), "wb") as stream:
        stream.write(b"gitdir: " + os.fsencode(admin) + b"\n")


def _recorded_nanos(recorded_at: object) -> int:
    """Convert a journal timestamp; millisecond truncation only moves it earlier."""
    moment = datetime.fromisoformat(str(recorded_at).replace("Z", "+00:00"))
    if moment.tzinfo is None:
        raise ValueError("interrupted-removal-time-unavailable")
    return int(moment.timestamp() * 1000) * 1_000_000


def removal_started(
    connection: sqlite3.Connection, event_id: str, planned_id: str | None = None,
) -> int | None:
    """Return the deletion-only boundary once removal start is journaled, else None.

    A start journaled before boundaries were persisted falls back to the earlier
    plan time (less clock slack): its snapshot check always followed planning.
    """
    row = connection.execute(
        "SELECT recorded_at, payload FROM events WHERE event_id=?", (event_id,),
    ).fetchone()
    if row is None:
        return None
    payload = json.loads(row[1])
    boundary = payload.get(BOUNDARY) if isinstance(payload, dict) else None
    if boundary is None:
        earlier = None if planned_id is None else connection.execute(
            "SELECT recorded_at FROM events WHERE event_id=?", (planned_id,),
        ).fetchone()
        boundary = _recorded_nanos((earlier or row)[0]) - CLOCK_SLACK_NS
    if isinstance(boundary, bool) or not isinstance(boundary, int) or boundary <= 0:
        raise ValueError("interrupted-removal-time-unavailable")
    return boundary


def require_deletion_only(
    target: Path, started: int, git: Callable[..., str],
) -> None:
    """Fail closed unless every remaining Git-visible path predates the boundary.

    `started` is the journaled validation boundary, not the removal timestamp.
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
