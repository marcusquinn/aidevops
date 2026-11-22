"""Admit a runtime-identified session owner before its first worktree write.

The caller supplies its own runtime PID and session identity, not command-authored
values. Ownership lasts until the native process ends or the session explicitly
relinquishes it; idle and tool completion are not release evidence. This API
does not discover writers or authorize cleanup.
"""

from pathlib import Path
from uuid import UUID, uuid4, uuid5

from .admission import AdmissionClosed, AdmissionRegistry
from .cleanup_plan import caller_ancestors
from .directory_handle import DirectoryHandle
from .enrollment import GenerationEnrollment
from .process import ProcessIdentity, ProcessObservation
from .runtime import adapter_for, require_ready
from .storage import LifecycleRegistry, StoreConflict, encode

RELINQUISHED = ProcessObservation("ended", "session-relinquished")


def _session_run_id(generation: str, session_id: str, identity: ProcessIdentity) -> str:
    """One run per generation, session and runtime generation; never reused."""
    return str(uuid5(UUID(generation), encode({
        "session": session_id, "identity": identity.to_dict(),
    })))


def _validate_session_id(session_id: str) -> None:
    if not isinstance(session_id, str) or not 0 < len(session_id) <= 256:
        raise ValueError("invalid-session-identity")


def admit_session(
    store: LifecycleRegistry, path: Path, pid: int, session_id: str,
) -> dict[str, object]:
    """Retry the same owner's admission, never a second native process launch."""
    _validate_session_id(session_id)
    adapter = adapter_for(store.installation_id())
    require_ready(adapter)
    identity = adapter.capture(pid)
    enrollment = GenerationEnrollment(store)
    with DirectoryHandle(path) as directory:
        try:
            generation = enrollment.resolve(path, create=True)
        except AdmissionClosed:
            # An existing owner may finish after admission closes. A new owner
            # still has to pass the transaction's open-generation check below.
            generation = enrollment.inspect(path)
        run_id = _session_run_id(generation, session_id, identity)
        created = AdmissionRegistry(store).admit(
            run_id, identity, generation, str(path),
        )
        with store.connection() as connection:
            row = connection.execute(
                "SELECT state FROM runs WHERE run_id=?", (run_id,),
            ).fetchone()
        if row is None or row["state"] == "ended":
            raise AdmissionClosed("session-owner-already-ended")
        if not directory.matches_path() or enrollment.inspect(path) != generation:
            raise StoreConflict("generation-changed-during-session-admission")
    return {
        "status": "admitted" if created else "existing-owner",
        "generation_id": generation,
        "run_id": run_id,
        "cleanup_authorized": False,
    }


def relinquish_session(
    store: LifecycleRegistry, path: Path, pid: int, session_id: str,
) -> dict[str, object]:
    """End only the calling session's own run on this tree (GH#37432).

    One OpenCode app serves many sessions under one PID, so its runs otherwise
    stay unfinished until the app quits, long after a session finished with a
    merged tree. #aidevops:trust-boundary — the runtime PID must be an ancestor
    of this command, so a session can end only a run its own runtime holds; the
    session identity selects that one run. Ending is permanent: re-admission
    refuses with session-owner-already-ended. Never closes admission, archives
    or removes; retirement stays with the registry's cleanup checks.
    """
    _validate_session_id(session_id)
    adapter = adapter_for(store.installation_id())
    require_ready(adapter)
    identity = adapter.capture(pid)
    if identity not in caller_ancestors(adapter):
        raise StoreConflict("relinquish-owner-not-caller")
    generation = GenerationEnrollment(store).inspect(path)
    run_id = _session_run_id(generation, session_id, identity)
    result: dict[str, object] = {
        "generation_id": generation, "run_id": run_id, "cleanup_authorized": False,
    }
    # One re-read covers a concurrent observation that moved the run version.
    for _ in range(2):
        with store.connection() as connection:
            row = connection.execute(
                "SELECT r.state, r.version FROM runs r JOIN bindings b USING(run_id) "
                "WHERE r.run_id=? AND b.generation_id=?", (run_id, generation),
            ).fetchone()
        if row is None:
            return dict(result, status="not-owner")
        if row["state"] == "ended":
            return dict(result, status="already-ended")
        try:
            store.observe(str(uuid4()), run_id, row["version"], RELINQUISHED)
        except StoreConflict:
            continue
        return dict(result, status="relinquished")
    raise StoreConflict("stale-observation")
