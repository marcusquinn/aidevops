"""Admit a runtime-identified session owner before its first worktree write.

The caller supplies its own runtime PID and session identity, not command-authored
values. Ownership lasts until the native process ends; idle and tool completion
are not release evidence. This API does not discover writers or authorize cleanup.
"""

from pathlib import Path
from uuid import UUID, uuid5

from .admission import AdmissionClosed, AdmissionRegistry
from .directory_handle import DirectoryHandle
from .enrollment import GenerationEnrollment
from .runtime import adapter_for, require_ready
from .storage import LifecycleRegistry, StoreConflict, encode


def admit_session(
    store: LifecycleRegistry, path: Path, pid: int, session_id: str,
) -> dict[str, object]:
    """Retry the same owner's admission, never a second native process launch."""
    if not isinstance(session_id, str) or not 0 < len(session_id) <= 256:
        raise ValueError("invalid-session-identity")
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
        run_id = str(uuid5(UUID(generation), encode({
            "session": session_id, "identity": identity.to_dict(),
        })))
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
