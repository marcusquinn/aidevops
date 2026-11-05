"""Verify completed retirement for a dated cleanup receipt; never retire a tree."""

from datetime import datetime
import hashlib
import json
import os
from pathlib import Path

from .retirement import _event, _event_id, _preserved
from .filesystem import checked_directory
from .storage import LifecycleRegistry, StoreConflict, encode


def _timestamp(value: str) -> datetime:
    """Parse UTC evidence without discarding admission or receipt precision."""
    if not value.endswith("Z"):
        raise ValueError("utc-receipt-timestamp-required")
    return datetime.fromisoformat(value[:-1] + "+00:00")


def _matching_plan(
    store: LifecycleRegistry, generation: str, path: Path, repository: str,
) -> "dict | None":
    """Match both terminal journal records before considering their dates."""
    planned = _event(store, _event_id(generation, "planned"))
    retired = _event(store, _event_id(generation, "retired"))
    if planned is None or retired is None:
        return None
    if (planned.get("type") != "retirement-planned"
            or retired.get("type") != "worktree-retired"):
        return None
    if (planned.get("generation_id") != generation
            or retired.get("generation_id") != generation):
        return None
    if (retired.get("preservation_id") != planned.get("preservation_id")
            or planned.get("source") != str(path)
            or planned.get("repo") != repository):
        return None
    return planned


def _archived_admissions(store: LifecycleRegistry, generation: str) -> list[str]:
    """Recover open-admission times from checksum-verified event archives.

    Earlier compaction could archive the admission event. Duplicate archive
    files (rollback leftovers) are collapsed by event identity; a conflicting
    duplicate or unreadable archive is ignored as untrusted evidence.
    """
    found: dict[str, tuple[str, str]] = {}
    for name in sorted(os.listdir(store.directory)):
        if not (name.startswith("events-archive-") and name.endswith(".json")):
            continue
        try:
            with checked_directory(store.directory) as directory_fd:
                descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
                with os.fdopen(descriptor, "rb") as stream:
                    document = json.load(stream)
            evidence = document["evidence"]
            if hashlib.sha256(encode(evidence).encode("utf-8")).hexdigest() != document["sha256"]:
                continue
            events = evidence["events"]
        except (OSError, ValueError, KeyError, TypeError):
            continue
        for row in events:
            try:
                payload = json.loads(row["payload"])
                if (payload.get("type") != "open-admission"
                        or payload.get("generation_id") != generation):
                    continue
                identity = (row["recorded_at"], row["payload"])
                if found.setdefault(row["event_id"], identity) != identity:
                    return []  # Same event identity, different content.
            except (KeyError, TypeError, ValueError, AttributeError):
                continue
    return [recorded for recorded, _ in found.values()]


def verify_retirement(
    store: LifecycleRegistry, path: Path, repository: str, branch: str,
    receipt_created_at: str,
) -> dict[str, object]:
    """Bind a terminal journal event and verified archive to the receipt identity.

    A missing directory alone is not evidence. A later enrollment cannot supply
    proof for an older receipt, and a replacement or remaining admission denies
    completion. Archive verification uses the existing preservation contract.
    """
    created = _timestamp(receipt_created_at)
    invalid_identity = not repository or not branch or not path.is_absolute()
    if (invalid_identity or path.parent.resolve(strict=True) != path.parent
            or os.path.lexists(path)):
        raise StoreConflict("retirement-proof-path-or-identity-invalid")
    with store.connection() as connection:
        if connection.execute(
            "SELECT 1 FROM generation_admissions WHERE path=?", (str(path),),
        ).fetchone():
            raise StoreConflict("retirement-proof-admission-remains")
        generations = [row[0] for row in connection.execute(
            "SELECT generation_id FROM generations WHERE path=?", (str(path),),
        )]
    candidates = []
    for generation in generations:
        planned = _matching_plan(store, generation, path, repository)
        if planned is None:
            continue
        with store.connection() as connection:
            opened = connection.execute(
                "SELECT recorded_at FROM events WHERE "
                "json_extract(payload,'$.type')='open-admission' AND "
                "json_extract(payload,'$.generation_id')=?", (generation,),
            ).fetchall()
            opened = [row[0] for row in opened] or _archived_admissions(store, generation)
            ended = connection.execute(
                "SELECT recorded_at FROM events WHERE event_id=?",
                (_event_id(generation, "retired"),),
            ).fetchone()
        if (len(opened) == 1 and ended is not None
                and _timestamp(opened[0]) <= created <= _timestamp(ended[0])):
            candidates.append((generation, planned))
    if len(candidates) != 1:
        raise StoreConflict("retirement-proof-missing-or-ambiguous")
    generation, plan = candidates[0]
    receipt = _preserved(store, plan, Path(plan["output_root"]))
    manifest_bytes = (Path(receipt["archive"]) / "manifest.json").read_bytes()
    manifest = json.loads(manifest_bytes)
    if hashlib.sha256(manifest_bytes).hexdigest() != receipt["manifest_sha256"]:
        raise StoreConflict("retirement-proof-archive-identity-changed")
    if (manifest.get("repo") != repository
            or manifest.get("branch") != branch
            or manifest.get("source_worktree") != str(path)
            or os.path.lexists(path)):
        raise StoreConflict("retirement-proof-archive-identity-changed")
    with store.connection() as connection:
        if connection.execute(
            "SELECT 1 FROM generation_admissions WHERE path=?", (str(path),),
        ).fetchone():
            raise StoreConflict("retirement-proof-admission-remains")
    return {
        "status": "retirement-verified", "generation_id": generation,
        "archive": receipt["archive"], "cleanup_authorized": False,
    }
