"""Accept confirmed disappearance without claiming preservation or deleting files."""

import json
from pathlib import Path
import sqlite3
from uuid import UUID, uuid5

from .cleanup_plan import _refresh_runs, _runs
from .directory_handle import DirectoryHandle
from .retirement import _event, _event_id, _lock
from .runtime import adapter_for, require_ready
from .storage import LifecycleRegistry, StoreConflict


def _absent(path: Path) -> bool:
    try:
        path.lstat()
    except FileNotFoundError:
        return True
    return False  # Includes dangling symlinks: never accept a replacement.


def _creation_id(generation: str) -> str:
    return str(uuid5(UUID(generation), "created-worktree"))


def _receipt_covered(receipt: dict, generation: str, rows: list[dict], path: Path) -> bool:
    """A creation receipt must name one of the registered, ended owners."""
    return any(receipt == {
        "type": "created-worktree", "generation_id": generation,
        "creator_run_id": row["run_id"], "path": str(path),
    } for row in rows)


def _owner_status(store: LifecycleRegistry, generation: str) -> tuple[str | None, list[dict]]:
    """Refresh bound owners; every one must be admitted and ended."""
    rows = _runs(store, generation)
    if not all(row["admitted"] for row in rows):
        return "coverage-gap", rows
    if rows:
        adapter = adapter_for(store.installation_id())
        require_ready(adapter)
        _refresh_runs(store, rows, adapter)
        rows = _runs(store, generation)
    if not all(row["admitted"] and row["state"] == "ended" for row in rows):
        return "waiting-for-runs", rows
    return None, rows


def _commit_absence(
    connection: sqlite3.Connection, path: Path,
    generation: str, rows: list[dict], parent: DirectoryHandle,
) -> dict:
    result = {"generation_id": generation, "cleanup_authorized": False}
    admission = connection.execute(
        "SELECT path FROM generation_admissions WHERE generation_id=?", (generation,),
    ).fetchone()
    if admission is None or admission["path"] != str(path):
        return dict(result, status="retry-required")
    current = connection.execute(
        "SELECT r.run_id,r.version,r.state FROM runs r JOIN bindings b USING(run_id) "
        "WHERE b.generation_id=? ORDER BY r.run_id", (generation,),
    ).fetchall()
    expected = sorted((row["run_id"], row["version"], "ended") for row in rows)
    if [tuple(row) for row in current] != expected:
        return dict(result, status="retry-required")
    creation = connection.execute(
        "SELECT payload FROM events WHERE event_id=?", (_creation_id(generation),),
    ).fetchone()
    if creation is not None and not _receipt_covered(
            json.loads(creation["payload"]), generation, rows, path):
        return dict(result, status="coverage-gap")
    if not _absent(path) or not parent.matches_path():
        return dict(result, status="retry-required")
    outcome = "source-disappeared" if creation else "creation-unconfirmed"
    evidence = dict(
        result, type="worktree-absence-reconciled", status="source-absent-reconciled",
        path=str(path), outcome=outcome, preservation="unverified",
        registered_runs=sorted(row["run_id"] for row in rows),
    )
    LifecycleRegistry._event(connection, _event_id(generation, "absence-reconciled"), evidence)
    released = connection.execute(
        "DELETE FROM generation_admissions WHERE generation_id=? AND path=?",
        (generation, str(path)),
    )
    if released.rowcount != 1:
        raise StoreConflict("absence-admission-changed")
    return evidence


def reconcile_absence(store: LifecycleRegistry, path: Path, generation: str) -> dict:
    """Fence retirement and admission; retain immutable history and all Git data.

    Empty reservations can finish only without a creation receipt. Owners must
    be admitted and ended. A missing parent is accepted only for an unbound,
    never-created reservation, without claiming preservation.
    """
    result = {"generation_id": generation, "cleanup_authorized": False}
    with _lock(store, generation):
        previous = _event(store, _event_id(generation, "absence-reconciled"))
        if previous is not None:
            if previous.get("path") != str(path):
                raise StoreConflict("absence-path-changed")
            return previous  # Replays never inspect a replacement generation.
        if _event(store, _event_id(generation, "planned")) is not None:
            return dict(result, status="retry-required")
        return _reconcile_source(store, path, generation)


def _reconcile_source(store: LifecycleRegistry, path: Path, generation: str) -> dict:
    result = {"generation_id": generation, "cleanup_authorized": False}
    try:
        parent = DirectoryHandle(path.parent)
    except FileNotFoundError:
        return _reconcile_missing_parent(store, path, generation)
    with parent:
        if not _absent(path):
            return dict(result, status="retry-required")
        status, rows = _owner_status(store, generation)
        if status is not None:
            return dict(result, status=status)
        # Serialize the snapshot validation, journal and admission release together.
        with store.connection(write=True) as connection:
            return _commit_absence(connection, path, generation, rows, parent)


def _reconcile_missing_parent(store: LifecycleRegistry, path: Path, generation: str) -> dict:
    """Release only an unowned reservation, atomically fenced against admission."""
    result = {"generation_id": generation, "cleanup_authorized": False}
    with store.connection(write=True) as connection:
        admission = connection.execute(
            "SELECT path FROM generation_admissions WHERE generation_id=?", (generation,),
        ).fetchone()
        if admission is None or admission["path"] != str(path):
            return dict(result, status="retry-required")
        bound = connection.execute(
            "SELECT 1 FROM bindings WHERE generation_id=?", (generation,),
        ).fetchone()
        creation = connection.execute(
            "SELECT 1 FROM events WHERE event_id=?", (_creation_id(generation),),
        ).fetchone()
        if bound or creation or not _absent(path.parent):
            return dict(result, status="source-absence-unconfirmed", reason="parent-missing")
        evidence = dict(
            result, type="worktree-absence-reconciled", status="source-absent-reconciled",
            path=str(path), reason="parent-missing", outcome="creation-unconfirmed",
            preservation="unverified", registered_runs=[],
        )
        LifecycleRegistry._event(connection, _event_id(generation, "absence-reconciled"), evidence)
        connection.execute("DELETE FROM generation_admissions WHERE generation_id=?", (generation,))
        return evidence


def path_reservations(store: LifecycleRegistry, path: Path) -> list[dict]:
    """Admission rows reserving this exact pathname, oldest generation ID first."""
    with store.connection() as connection:
        return [dict(row) for row in connection.execute(
            "SELECT generation_id,path,state FROM generation_admissions "
            "WHERE path=? ORDER BY generation_id", (str(path),),
        )]


def reservation_blocker(store: LifecycleRegistry, path: Path, generation: str) -> str | None:
    """Preflight the `reconcile_absence` fences while the pathname is occupied.

    Returns the status reconciliation would report, or None when only source
    absence is missing. Never mutates admission; refreshing owners is observation.
    """
    if _event(store, _event_id(generation, "absence-reconciled")) is not None:
        return "already-reconciled"
    if _event(store, _event_id(generation, "planned")) is not None:
        return "retry-required"
    status, rows = _owner_status(store, generation)
    if status is not None:
        return status
    creation = _event(store, _creation_id(generation))
    if creation is not None and not _receipt_covered(creation, generation, rows, path):
        return "coverage-gap"
    return None


def reconcile_path(store: LifecycleRegistry, path: Path) -> dict:
    """Release stale reservations of one absent pathname before re-creation (GH#37706).

    Absence is provable immediately before a producer re-creates a fixed path.
    Each reserving generation goes through `reconcile_absence`, so the recorded
    retirement plan, admitted-and-ended owners and creation receipt fences all
    still apply. A present path is never inspected or reconciled here.
    """
    result: dict = {"path": str(path), "cleanup_authorized": False, "results": []}
    if not path.is_absolute():
        raise ValueError("absolute-path-required")
    if not _absent(path):
        return dict(result, status="path-present")
    generations = [row["generation_id"] for row in path_reservations(store, path)]
    if not generations:
        return dict(result, status="no-reservation")
    outcomes = [reconcile_absence(store, path, generation) for generation in generations]
    released = all(outcome.get("status") == "source-absent-reconciled" for outcome in outcomes)
    return dict(result, status="path-released" if released else "reservation-retained",
                results=outcomes)
