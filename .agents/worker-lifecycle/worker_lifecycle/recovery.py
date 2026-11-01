"""Bind recovery to current closed admission, without asserting past creation."""

import json
from pathlib import Path
from uuid import UUID, uuid5

from .cleanup_plan import _runs, prepare_cleanup
from .enrollment import GenerationEnrollment, _directory_inode, _git_directory
from .storage import LifecycleRegistry, StoreConflict


def recovery_evidence(
    store: LifecycleRegistry, path: Path, generation: str,
) -> dict:
    """Require the exact enrolled directory and all admitted owners to be ended."""
    if GenerationEnrollment(store).inspect(path) != generation:
        raise StoreConflict("recovery-generation-changed")
    with store.connection() as connection:
        admission = connection.execute(
            "SELECT state FROM generation_admissions WHERE generation_id=?",
            (generation,),
        ).fetchone()
    rows = _runs(store, generation)
    if (admission is None or admission["state"] != "closed" or not rows
            or not all(row["admitted"] and row["state"] == "ended" for row in rows)):
        raise StoreConflict("recovery-owner-evidence-incomplete")
    admin = _git_directory(path)
    return {
        "type": "worktree-recovery-authorized", "generation_id": generation,
        "path": str(path), "directory_identity": _directory_inode(path),
        "git_directory": str(admin), "git_identity": _directory_inode(admin),
        "admitted_runs": sorted(row["run_id"] for row in rows),
    }


def prepare_retirement(
    store: LifecycleRegistry, path: Path, generation: str, recover: bool,
) -> dict:
    """Require creation provenance or explicitly journal current recovery evidence."""
    with store.connection() as connection:
        row = connection.execute(
            "SELECT payload FROM events WHERE event_id=?",
            (str(uuid5(UUID(generation), "created-worktree")),),
        ).fetchone()
    creation = json.loads(row["payload"]) if row else None
    verified = any(row["admitted"] and creation == {
        "type": "created-worktree", "generation_id": generation,
        "creator_run_id": row["run_id"], "path": str(path),
    } for row in _runs(store, generation))
    if not verified and (creation is not None or not recover):
        return {"status": "coverage-gap", "cleanup_authorized": False}
    if GenerationEnrollment(store).inspect(path) != generation:
        raise StoreConflict("generation-changed")
    prepared = prepare_cleanup(store, path)
    if prepared["status"] == "registered-runs-ended" and creation is None:
        evidence = recovery_evidence(store, path, generation)
        with store.connection(write=True) as connection:
            store._event(connection, str(uuid5(UUID(generation),
                         "retirement-recovered")), evidence)
    return prepared
