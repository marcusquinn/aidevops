"""Authority evidence for the observation-era takeover of stranded managed worktrees.

Remote recoverability alone never proves this host created the worktree: a
modern generation is taken over only with closed admission, complete owner
evidence and, for a detached HEAD, a verified creation receipt.
"""

import json
from pathlib import Path
import sqlite3
from uuid import UUID, uuid5

from .cleanup_plan import _runs, enrolled_only_authorized, prepare_cleanup
from .process import ObservationUnavailable


def close_quiescent_admission(store, item):
    """Close a stranded admission once every bound run has ended (GH#37101 cause 2).

    Uses the admission pass's own primitive, which re-samples bound runs and
    closes only when every run is admitted and ended. Unenrolled, changed, empty
    or unfinished generations stay open, so the authority check that follows
    still reports `managed-admission-not-closed`. Never called in preview.
    """
    try:
        prepare_cleanup(store, Path(item["path"]))
    except (ValueError, OSError, sqlite3.Error, ObservationUnavailable):
        return


def _require_closed_admission(connection, generation):
    """Raise unless the generation admission is closed."""
    admission = connection.execute(
        "SELECT state FROM generation_admissions WHERE generation_id=?",
        (generation,),
    ).fetchone()
    if admission is None or admission["state"] != "closed":
        raise ValueError("managed-admission-not-closed")


def _require_owner_evidence(store, generation):
    """Raise unless owner runs have ended or the operator authorized takeover."""
    rows = _runs(store, generation)
    if not rows and not enrolled_only_authorized(store, generation):
        raise ValueError("managed-operator-authorization-required")
    if not all(row["admitted"] and row["state"] == "ended" for row in rows):
        raise ValueError("managed-owner-evidence-incomplete")
    return rows


def _creation_verified(connection, generation, rows, path):
    """Return True when worktree creation is recorded for the generation."""
    event = connection.execute(
        "SELECT payload FROM events WHERE event_id=?",
        (str(uuid5(UUID(generation), "created-worktree")),),
    ).fetchone()
    if not event:
        return False
    creation = json.loads(event["payload"])
    return any(row["admitted"] and creation == {
        "type": "created-worktree", "generation_id": generation,
        "creator_run_id": row["run_id"], "path": path,
    } for row in rows)


def require_managed_authority(store, connection, item, plan):
    """Closed admission is mandatory; recoverability never proves creation."""
    if not item["generations"]:
        raise ValueError("managed-admission-evidence-missing")
    creation_verified = False
    for generation in item["generations"]:
        _require_closed_admission(connection, generation)
        rows = _require_owner_evidence(store, generation)
        creation_verified |= _creation_verified(connection, generation, rows, item["path"])
    if plan["branch"] == "HEAD" and not creation_verified:
        raise ValueError("managed-detached-creation-unverified")
