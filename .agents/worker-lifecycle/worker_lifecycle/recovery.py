"""Bind recovery to current closed admission, without asserting past creation."""

import json
from pathlib import Path
from uuid import UUID, uuid5

from .cleanup_plan import _runs, enrolled_only_authorized, prepare_cleanup
from .reclaim.unowned import unowned_authorized
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
    # Reclaim's evidence-backed event (GH#38405) is preferred and named as such;
    # the legacy operator-confirmed event is removed with the legacy path.
    proof: dict[str, object] | None = None
    if not rows and unowned_authorized(store, generation):
        proof = {"authorization": "reclaim"}
    elif not rows and enrolled_only_authorized(store, generation):
        proof = {"operator_confirmed": True}
    if proof is not None:
        admin = _git_directory(path)
        return {
            "type": "worktree-recovery-authorized", "generation_id": generation,
            "path": str(path), "directory_identity": _directory_inode(path),
            "git_directory": str(admin), "git_identity": _directory_inode(admin),
            "admitted_runs": [], **proof,
        }
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
        event_id = str(uuid5(UUID(generation), "retirement-recovered"))
        with store.connection(write=True) as connection:
            stored = connection.execute(
                "SELECT payload FROM events WHERE event_id=?", (event_id,),
            ).fetchone()
            # The stored evidence already authorized this exact tree; a later
            # proof kind (legacy confirmation, then Reclaim) is not a conflict.
            if stored is None or not _same_tree(json.loads(stored["payload"]), evidence):
                store._event(connection, event_id, evidence)
    return prepared


# Which never-owned authorization was current; the rest identifies the tree.
_PROOF_KEYS = frozenset({"authorization", "operator_confirmed"})


def _same_tree(stored: object, evidence: dict) -> bool:
    """True when two recovery records differ at most in their proof kind (GH#38417)."""
    if not isinstance(stored, dict):
        return False
    return ({key: value for key, value in stored.items() if key not in _PROOF_KEYS}
            == {key: value for key, value in evidence.items() if key not in _PROOF_KEYS})
