"""Release a path reservation whose generation no longer occupies the path.

Fixed-path producers (Buzz host agents) re-create a tree at the same path. A
generation whose tree disappeared before retirement finished keeps its unique
path reservation, so the replacement can never enroll (GH#37706).

`release_vacant_path` runs before creation, while absence is provable, and
reuses the fenced absence reconciliation. `release_replaced_path` is the
operator-confirmed recovery once a replacement already occupies the path. It
deletes no files; immutable history and every Git object are retained.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from uuid import UUID, uuid5

from .absence import reconcile_absence
from .cleanup_plan import _refresh_runs, _runs
from .enrollment import MARKER, _git_directory
from .retirement import _event, _event_id, _lock
from .runtime import adapter_for, require_ready
from .storage import LifecycleRegistry, StoreConflict


def _reservation(store: LifecycleRegistry, path: Path) -> dict | None:
    with store.connection() as connection:
        row = connection.execute(
            "SELECT generation_id,state FROM generation_admissions WHERE path=?",
            (str(path),),
        ).fetchone()
    return dict(row) if row else None


def _present(path: Path) -> bool:
    try:
        path.lstat()
    except FileNotFoundError:
        return False
    return True  # Includes dangling symlinks: never treated as absence.


def _canonical(path: Path) -> Path:
    if not path.is_absolute() or path.parent.resolve(strict=True) != path.parent:
        raise ValueError("canonical-parent-required")
    return path


def release_vacant_path(store: LifecycleRegistry, path: Path) -> dict:
    """Release the reservation of an absent path through absence reconciliation.

    Never touches a present path. Live, unknown or unadmitted owners and planned
    relocations keep the reservation (see `absence.reconcile_absence`).
    """
    path = _canonical(path)
    result: dict = {"path": str(path), "cleanup_authorized": False}
    reservation = _reservation(store, path)
    if reservation is None:
        return dict(result, status="no-reservation")
    if _present(path):
        return dict(result, status="path-present",
                    generation_id=reservation["generation_id"])
    return dict(reconcile_absence(store, path, reservation["generation_id"]),
                path=str(path))


def release_replaced_path(store: LifecycleRegistry, path: Path, confirm: bool) -> dict:
    """Operator-confirmed release of a reservation whose tree was replaced.

    Eligible only when the tree now at the path is a linked worktree whose Git
    admin directory has no generation marker, the reserving generation has no
    planned relocation, and every bound run was admitted and has ended. The
    operator confirms the replacement is not the reserving generation with its
    marker removed. Preview by default; confirmation journals the evidence and
    releases the reservation in one writer transaction.
    """
    path = _canonical(path)
    result: dict = {"path": str(path), "cleanup_authorized": False}
    reservation = _reservation(store, path)
    if reservation is None:
        return dict(result, status="no-reservation")
    generation = reservation["generation_id"]
    result.update(generation_id=generation, admission=reservation["state"])
    if not _present(path):
        return dict(result, status="path-absent", next="release-vacant-path")
    with _lock(store, generation):
        candidate = _replacement_candidate(store, path, generation)
        if candidate.refusal is None and confirm:
            return _commit_release(store, candidate, result)
    preview = {
        "status": "replaced-path-preview", "confirm_required": True,
        "registered_runs": sorted(row["run_id"] for row in candidate.rows),
    }
    return dict(result, **(candidate.refusal or preview))


@dataclass
class _Candidate:
    """Reserving generation and evidence gathered under its retirement lock."""

    path: Path
    generation: str
    rows: list = field(default_factory=list)
    directory: Path | None = None
    refusal: dict | None = None


def _replacement_candidate(store: LifecycleRegistry, path: Path, generation: str) -> _Candidate:
    candidate = _Candidate(path, generation)
    if _event(store, _event_id(generation, "planned")) is not None:
        candidate.refusal = {"status": "retry-required", "reason": "retirement-planned"}
        return candidate
    candidate.directory = _git_directory(path)
    if os.path.lexists(candidate.directory / MARKER):
        candidate.refusal = {"status": "path-holds-enrolled-tree"}
    else:
        candidate.rows, candidate.refusal = _settled_runs(store, generation)
    return candidate


def _settled_runs(store: LifecycleRegistry, generation: str) -> tuple[list, dict | None]:
    """Return bound runs and a refusal unless every run was admitted and has ended."""
    rows = _runs(store, generation)
    if not all(row["admitted"] for row in rows):
        return rows, {"status": "coverage-gap"}
    if any(row["state"] != "ended" for row in rows):
        adapter = adapter_for(store.installation_id())
        require_ready(adapter)
        _refresh_runs(store, rows, adapter)
        rows = _runs(store, generation)
    settled = all(row["admitted"] and row["state"] == "ended" for row in rows)
    return rows, None if settled else {"status": "waiting-for-runs"}


def _commit_release(store: LifecycleRegistry, candidate: _Candidate, result: dict) -> dict:
    path, generation, rows = candidate.path, candidate.generation, candidate.rows
    directory = candidate.directory
    expected = sorted((row["run_id"], row["version"], "ended") for row in rows)
    with store.connection(write=True) as connection:
        admission = connection.execute(
            "SELECT path FROM generation_admissions WHERE generation_id=?", (generation,),
        ).fetchone()
        if admission is None or admission["path"] != str(path):
            return dict(result, status="retry-required")
        current = connection.execute(
            "SELECT r.run_id,r.version,r.state FROM runs r JOIN bindings b USING(run_id) "
            "WHERE b.generation_id=? ORDER BY r.run_id", (generation,),
        ).fetchall()
        if [tuple(row) for row in current] != expected:
            return dict(result, status="retry-required")
        if (directory is None or os.path.lexists(directory / MARKER)
                or _git_directory(path) != directory):
            return dict(result, status="retry-required")
        evidence = dict(
            result, type="replaced-path-released", status="replaced-path-released",
            operator_confirmed=True, preservation="unverified",
            registered_runs=sorted(row["run_id"] for row in rows),
        )
        LifecycleRegistry._event(
            connection, str(uuid5(UUID(generation), "replaced-path-released")), evidence,
        )
        released = connection.execute(
            "DELETE FROM generation_admissions WHERE generation_id=? AND path=?",
            (generation, str(path)),
        )
        if released.rowcount != 1:
            raise StoreConflict("replaced-path-admission-changed")
        return evidence
