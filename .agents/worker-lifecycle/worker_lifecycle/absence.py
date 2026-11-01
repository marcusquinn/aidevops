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


def _commit_absence(
    store: LifecycleRegistry, connection: sqlite3.Connection, path: Path,
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
        "SELECT payload FROM events WHERE event_id=?",
        (str(uuid5(UUID(generation), "created-worktree")),),
    ).fetchone()
    if creation is not None:
        receipt = json.loads(creation["payload"])
        if not any(receipt == {
            "type": "created-worktree", "generation_id": generation,
            "creator_run_id": row["run_id"], "path": str(path),
        } for row in rows):
            return dict(result, status="coverage-gap")
    if not _absent(path) or not parent.matches_path():
        return dict(result, status="retry-required")
    outcome = "source-disappeared" if creation else "creation-unconfirmed"
    evidence = dict(
        result, type="worktree-absence-reconciled", status="source-absent-reconciled",
        path=str(path), outcome=outcome, preservation="unverified",
        registered_runs=sorted(row["run_id"] for row in rows),
    )
    store._event(connection, _event_id(generation, "absence-reconciled"), evidence)
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
    be admitted and ended. A missing parent is not proof of source disappearance.
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
        try:
            parent = DirectoryHandle(path.parent)
        except FileNotFoundError:
            return dict(result, status="source-absence-unconfirmed", reason="parent-missing")
        with parent:
            if not _absent(path):
                return dict(result, status="retry-required")
            rows = _runs(store, generation)
            if not all(row["admitted"] for row in rows):
                return dict(result, status="coverage-gap")
            if rows:
                adapter = adapter_for(store.installation_id())
                require_ready(adapter)
                _refresh_runs(store, rows, adapter)
                rows = _runs(store, generation)
            if not all(row["admitted"] and row["state"] == "ended" for row in rows):
                return dict(result, status="waiting-for-runs")
            # The same writer transaction excludes new admissions while checking
            # the exact owner set, recording the outcome and releasing the path.
            with store.connection(write=True) as connection:
                return _commit_absence(store, connection, path, generation, rows, parent)
