"""Prepare registered runs for cleanup; never archive, remove or infer writers."""

import json
import os
from pathlib import Path
import time
from uuid import UUID, uuid4, uuid5

from .admission import AdmissionRegistry
from .enrollment import GenerationEnrollment
from .process import ObservationUnavailable, ProcessAdapter, ProcessIdentity
from .runtime import adapter_for, require_ready
from .storage import LifecycleRegistry, StoreConflict

ANCESTOR_LIMIT = 64


def _is_admitted(payload: object, row: dict, generation: str) -> bool:
    if not isinstance(payload, dict):
        return False
    expected = {
        "type": "admit", "run_id": row["run_id"], "generation_id": generation,
        "identity": json.loads(row["identity"]),
    }
    return all(payload.get(key) == value for key, value in expected.items())


def _runs(store: LifecycleRegistry, generation: str) -> list[dict]:
    with store.connection() as connection:
        rows = connection.execute(
            "SELECT r.* FROM runs r JOIN bindings b USING(run_id) "
            "WHERE b.generation_id=? ORDER BY r.checked_sequence,r.run_id",
            (generation,),
        ).fetchall()
        result = []
        for row in rows:
            event = connection.execute(
                "SELECT payload FROM events WHERE event_id=?",
                (str(uuid5(UUID(row["run_id"]), "admit")),),
            ).fetchone()
            payload = json.loads(event["payload"]) if event else {}
            admitted = _is_admitted(payload, dict(row), generation)
            result.append(dict(row, admitted=admitted))
        return result


def enrolled_only_event_id(generation: str) -> str:
    return str(uuid5(UUID(generation), "enrolled-only-authorized"))


def enrolled_only_authorized(store: LifecycleRegistry, generation: str) -> bool:
    """True only for the operator-confirmed, closed, never-owned generation."""
    with store.connection() as connection:
        event = connection.execute(
            "SELECT payload FROM events WHERE event_id=?",
            (enrolled_only_event_id(generation),),
        ).fetchone()
        admission = connection.execute(
            "SELECT state FROM generation_admissions WHERE generation_id=?",
            (generation,),
        ).fetchone()
    expected = {
        "type": "enrolled-only-retirement-authorized",
        "generation_id": generation, "operator_confirmed": True,
    }
    if event is None or admission is None:
        return False
    if json.loads(event["payload"]) != expected or admission["state"] != "closed":
        return False
    return not _runs(store, generation)


def _refresh_runs(
    store: LifecycleRegistry, rows: list[dict], adapter: ProcessAdapter,
) -> None:
    deadline = time.monotonic() + 5
    for row in rows:
        if time.monotonic() >= deadline:
            break
        if row["state"] == "ended":
            continue
        identity = ProcessIdentity.from_dict(json.loads(row["identity"]))
        observation = adapter.observe(identity)
        if not store.refresh_unchanged(row["run_id"], row["version"], observation):
            store.observe(str(uuid4()), row["run_id"], row["version"], observation)


def caller_ancestors(adapter: ProcessAdapter) -> set[ProcessIdentity]:
    """Native identities of the invoking process's ancestors (GH#37022).

    Starts at the parent: the runtime that owns a session is always an ancestor
    of the cleanup command, never the command itself. A process this user
    cannot observe ends the walk, so the set is a subset, never a guess.
    """
    parent = getattr(adapter, "parent", None)
    identities: set[ProcessIdentity] = set()
    if parent is None:
        return identities
    pid = os.getppid()
    for _ in range(ANCESTOR_LIMIT):
        if pid <= 1:
            break
        try:
            identities.add(adapter.capture(pid))
            pid = parent(pid)
        except (ObservationUnavailable, ValueError, OSError):
            break
    return identities


def _caller_owns_all(rows: list[dict], adapter: ProcessAdapter) -> bool:
    """True when every unfinished run is this command's own ancestor runtime.

    #aidevops:trust-boundary — diagnosis only. One runtime PID can serve several
    sessions, so a caller-owned run still blocks retirement; this only lets the
    refusal name the caller instead of an anonymous owner. The owning session
    may end its own run with relinquish-session (GH#37432).
    """
    ancestors = caller_ancestors(adapter)
    if not ancestors:
        return False
    try:
        identities = [ProcessIdentity.from_dict(json.loads(row["identity"])) for row in rows]
    except (ValueError, TypeError):
        return False
    return all(identity in ancestors for identity in identities)


def _close_quiescent(
    store: LifecycleRegistry, path: Path, generation: str, result: dict[str, object],
    adapter: ProcessAdapter,
) -> dict[str, object]:
    enrollment = GenerationEnrollment(store)
    rows = _runs(store, generation)
    if enrollment.inspect(path) != generation:
        raise StoreConflict("generation-changed-during-preparation")
    if not rows or not all(row["admitted"] for row in rows):
        return result
    result["registered_runs"] = len(rows)
    unfinished = [row for row in rows if row["state"] != "ended"]
    result["unfinished_runs"] = len(unfinished)
    if unfinished:
        result["status"] = "waiting-for-runs"
        if _caller_owns_all(unfinished, adapter):
            result["detail"] = "waiting-for-caller"
        return result
    try:
        AdmissionRegistry(store).close_generation(
            str(uuid5(UUID(generation), "prepare-cleanup-close")), generation,
            expected_ended_runs=tuple(row["run_id"] for row in rows),
        )
    except StoreConflict:
        result["status"] = "retry-required"
        return result
    result["admission"] = "closed"
    if enrollment.inspect(path) != generation:
        raise StoreConflict("generation-changed-during-preparation")
    rows = _runs(store, generation)
    covered = rows and all(row["admitted"] and row["state"] == "ended" for row in rows)
    result["status"] = "registered-runs-ended" if covered else "coverage-gap"
    return result


def prepare_cleanup(store: LifecycleRegistry, path: Path) -> dict[str, object]:
    """Sample bound runs, then conditionally close quiescent admission permanently.

    Ended registered runs are necessary, not sufficient, for removal. This does
    not establish launcher coverage or verify a WIP archive. Empty, uncovered or
    unfinished run sets do not close admission. Retry is idempotent; a failure
    after successful closure intentionally leaves admission closed.
    """
    enrollment = GenerationEnrollment(store)
    generation = enrollment.inspect(path)
    adapter = adapter_for(store.installation_id())
    require_ready(adapter)
    with store.connection() as connection:
        admission = connection.execute(
            "SELECT state FROM generation_admissions WHERE generation_id=?",
            (generation,),
        ).fetchone()
        if admission is None:
            raise StoreConflict("generation-not-registered")
    result: dict[str, object] = {
        "generation_id": generation,
        "admission": admission["state"],
        "cleanup_authorized": False,
        "status": "coverage-gap",
    }
    rows = _runs(store, generation)
    with store.connection() as connection:
        creation = connection.execute(
            "SELECT payload FROM events WHERE event_id=?",
            (str(uuid5(UUID(generation), "created-worktree")),),
        ).fetchone()
    receipt = json.loads(creation["payload"]) if creation else None
    result["creation_verified"] = any(
        row["admitted"] and receipt == {
            "type": "created-worktree", "generation_id": generation,
            "creator_run_id": row["run_id"], "path": str(path),
        }
        for row in rows
    )
    if not rows and enrolled_only_authorized(store, generation):
        return dict(result, status="registered-runs-ended", admission="closed",
                    enrolled_only=True)
    if not rows or not all(row["admitted"] for row in rows):
        return result
    try:
        _refresh_runs(store, rows, adapter)
    except StoreConflict:
        result["status"] = "retry-required"
        return result
    return _close_quiescent(store, path, generation, result, adapter)
