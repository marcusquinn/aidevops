"""Retire controlled worktrees via a journaled private Git relocation.

The original public pathname is never passed to Git removal. Partial deletion
that cannot be reverified stops with its archive and remaining data retained.
"""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
from uuid import UUID, uuid5

from .cleanup_plan import _runs, prepare_cleanup
from .directory_handle import DirectoryHandle
from .enrollment import (
    MARKER, GenerationEnrollment, _directory_inode, _git_directory, _read_marker,
)
from .preservation import (
    SCRIPTS, _run, _snapshot, inherit_operation_lock, preserve_wip, verify_restoration,
)
from .storage import LifecycleRegistry, StoreConflict, _private


@dataclass(frozen=True)
class ArchiveTarget:
    repository: str
    base_branch: str
    root: Path


def _id(path: Path) -> list[int]:
    info = path.lstat()
    return [info.st_dev, info.st_ino]


def _event_id(generation: str, phase: str) -> str:
    return str(uuid5(UUID(generation), f"retirement-{phase}"))


def _event(store: LifecycleRegistry, key: str) -> dict | None:
    with store.connection() as connection:
        row = connection.execute(
            "SELECT payload FROM events WHERE event_id=?", (key,),
        ).fetchone()
    value = json.loads(row["payload"]) if row else None
    if value is not None and not isinstance(value, dict):
        raise StoreConflict("invalid-retirement-event")
    return value


def _record(store: LifecycleRegistry, generation: str, phase: str, data: dict) -> None:
    with store.connection(write=True) as connection:
        store._event(connection, _event_id(generation, phase), data)


@contextmanager
def _lock(store: LifecycleRegistry, generation: str) -> Iterator[None]:
    path = store.directory / f"retirement-{generation}.lock"
    descriptor = os.open(
        path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600,
    )
    try:
        _private(path)
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                or info.st_size != 0 or _id(path) != [info.st_dev, info.st_ino]):
            raise StoreConflict("invalid-retirement-lock")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # Close our descriptor, never explicitly unlock the shared description:
        # an already-started helper may still own it after controller death.
        with inherit_operation_lock(descriptor):
            yield
    finally:
        os.close(descriptor)


def _git(*arguments: str) -> str:
    # Reuse the framework resolver, not a PATH shim or a second resolver policy.
    spec = importlib.util.spec_from_file_location(
        "lifecycle_native_git", SCRIPTS / "native_git.py",
    )
    if spec is None or spec.loader is None:
        raise ValueError("native-git-resolver-unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    try:
        executable = module.real_git()
    except RuntimeError as error:
        raise ValueError("native-git-unavailable") from error
    return _run([executable, *arguments])


def _preserved(store: LifecycleRegistry, plan: dict, root: Path) -> dict:
    receipt = _event(store, plan["preservation_id"])
    if (receipt is None or receipt.get("type") != "wip-preserved"
            or receipt.get("generation_id") != plan["generation_id"]):
        raise StoreConflict("preservation-receipt-unavailable")
    archive = Path(receipt["archive"])
    if archive.resolve(strict=True) != archive or not archive.is_relative_to(root):
        raise StoreConflict("archive-outside-output-root")
    _private(archive, directory=True)
    digest = hashlib.sha256((archive / "manifest.json").read_bytes()).hexdigest()
    if digest != receipt["manifest_sha256"]:
        raise StoreConflict("archive-manifest-changed")
    common = Path(plan["common"])
    if (common.resolve(strict=True) != common
            or _directory_inode(common) != plan["common_identity"]
            or _git("--git-dir", str(common), "rev-parse", "--verify",
                    receipt["base_ref"]) != receipt["base_sha"]):
        raise StoreConflict("common-repository-or-base-pin-changed")
    manifest = verify_restoration(archive, root, receipt["snapshot"])
    if manifest.get("source_worktree") != plan["source"]:
        raise StoreConflict("archive-source-changed")
    return receipt


def _new_plan(
    store: LifecycleRegistry, path: Path, generation: str, archive: ArchiveTarget,
) -> dict:
    repo, base, root = archive.repository, archive.base_branch, archive.root
    preserved = preserve_wip(store, path, repo, base, root)
    if (preserved["status"] != "wip-archive-verified"
            or preserved["generation_id"] != generation):
        raise StoreConflict("preservation-incomplete")
    admin = _git_directory(path)
    common = Path(_git("-C", str(path), "rev-parse", "--path-format=absolute",
                       "--git-common-dir"))
    container = Path(tempfile.mkdtemp(prefix=".lifecycle-retire-", dir=path.parent))
    plan = {
        "type": "retirement-planned", "generation_id": generation,
        "source": str(path), "repo": repo, "base": base, "output_root": str(root),
        "container": str(container),
        "container_identity": _directory_inode(container),
        "directory_identity": _directory_inode(path), "git_directory": str(admin),
        "git_identity": _directory_inode(admin), "common": str(common),
        "common_identity": _directory_inode(common),
        "preservation_id": preserved["operation_id"],
    }
    _record(store, generation, "planned", plan)
    return plan


def _relocate_source(
    store: LifecycleRegistry, path: Path, plan: dict, receipt: dict,
) -> None:
    with DirectoryHandle(path) as original:
        prepared = prepare_cleanup(store, path)
        if (prepared["generation_id"] != plan["generation_id"]
                or not prepared["creation_verified"]
                or prepared["status"] != "registered-runs-ended"):
            raise StoreConflict("source-changed-before-relocation")
        if (_directory_inode(path) != plan["directory_identity"]
                or _snapshot(path) != receipt["snapshot"]
                or not original.matches_path()):
            raise StoreConflict("source-changed-before-relocation")
        # No force: Git locks and unsupported moves must stop the operation.
        target = Path(plan["container"]) / "tree"
        _git("--git-dir", plan["common"], "worktree", "move", str(path), str(target))


def _remove_private(
    store: LifecycleRegistry, path: Path, plan: dict, receipt: dict,
) -> None:
    target, admin = Path(plan["container"]) / "tree", Path(plan["git_directory"])
    generation = plan["generation_id"]
    with DirectoryHandle(target) as tree, DirectoryHandle(admin) as metadata:
        marker = {
            "format": 2, "installation_id": store.installation_id(),
            "generation_id": generation, "path": str(path),
            "directory": plan["directory_identity"],
            "git_directory": str(admin), "git_identity": plan["git_identity"],
        }
        if (_directory_inode(target) != plan["directory_identity"]
                or _git_directory(target) != admin
                or _directory_inode(admin) != plan["git_identity"]):
            raise StoreConflict("private-worktree-changed")
        if (_read_marker(admin / MARKER) != marker
                or _snapshot(target) != receipt["snapshot"]
                or not tree.matches_path() or not metadata.matches_path()):
            raise StoreConflict("private-worktree-changed")
        _record(store, generation, "removing", {
            "type": "retirement-removing", "generation_id": generation,
        })
        # One force permits archived dirty/ignored state, never a Git lock.
        _git("--git-dir", plan["common"], "worktree", "remove", "--force", str(target))


def _finish(
    store: LifecycleRegistry, path: Path, generation: str, plan: dict, root: Path,
) -> dict[str, object]:
    receipt = _preserved(store, plan, root)
    result: dict[str, object] = {
        "generation_id": generation, "status": "retired",
        "archive": receipt["archive"], "common_repository_required": True,
        "cleanup_authorized": False,
    }
    if _event(store, _event_id(generation, "retired")) is not None:
        return result  # Never inspect/remove a replacement at the public name.
    with store.connection() as connection:
        admission = connection.execute(
            "SELECT state FROM generation_admissions WHERE generation_id=?",
            (generation,),
        ).fetchone()
    rows = _runs(store, generation)
    if (admission is None or admission["state"] != "closed" or not rows
            or not all(row["admitted"] and row["state"] == "ended" for row in rows)):
        raise StoreConflict("retirement-owner-evidence-changed")
    container = Path(plan["container"])
    if (container.parent != path.parent
            or not container.name.startswith(".lifecycle-retire-")
            or container.resolve(strict=True) != container
            or _directory_inode(container) != plan["container_identity"]):
        raise StoreConflict("retirement-container-changed")
    _private(container, directory=True)
    target = container / "tree"
    admin = Path(plan["git_directory"])
    removing = _event(store, _event_id(generation, "removing"))
    if not os.path.lexists(target) and removing is None:
        _relocate_source(store, path, plan, receipt)
    if os.path.lexists(target):
        _remove_private(store, path, plan, receipt)
    elif removing is None or os.path.lexists(admin):
        raise StoreConflict("retirement-outcome-unverified")
    if os.path.lexists(target):
        raise StoreConflict("private-worktree-still-present")
    with store.connection(write=True) as connection:
        released = connection.execute(
            "DELETE FROM generation_admissions "
            "WHERE generation_id=? AND state='closed'",
            (generation,),
        )
        if released.rowcount != 1:
            raise StoreConflict("retirement-admission-changed")
        store._event(connection, _event_id(generation, "retired"), {
            "type": "worktree-retired", "generation_id": generation,
            "preservation_id": plan["preservation_id"],
        })
    try:
        container.rmdir()  # Empty owned container only; never recursive cleanup.
    except OSError:
        result["container_cleanup_pending"] = True
    return result


def retire_worktree(
    store: LifecycleRegistry, path: Path, generation: str, archive: ArchiveTarget,
) -> dict[str, object]:
    """Execute only for controlled, quiescent generations with verified archives."""
    repo, base, root = archive.repository, archive.base_branch, archive.root
    if not path.is_absolute() or path.parent.resolve(strict=True) != path.parent:
        raise ValueError("canonical-source-parent-required")
    if not root.is_absolute() or root.resolve(strict=True) != root:
        raise ValueError("canonical-output-root-required")
    _private(root, directory=True)
    generation = str(UUID(generation))
    with store.connection() as connection:
        row = connection.execute(
            "SELECT path FROM generations WHERE generation_id=?", (generation,),
        ).fetchone()
    if row is None or row["path"] != str(path):
        raise StoreConflict("generation-path-mismatch")
    with _lock(store, generation):
        plan = _event(store, _event_id(generation, "planned"))
        if plan is None:
            creation = _event(store, str(uuid5(UUID(generation), "created-worktree")))
            if not any(row["admitted"] and creation == {
                "type": "created-worktree", "generation_id": generation,
                "creator_run_id": row["run_id"], "path": str(path),
            } for row in _runs(store, generation)):
                return {"status": "coverage-gap", "cleanup_authorized": False}
            if GenerationEnrollment(store).inspect(path) != generation:
                raise StoreConflict("generation-changed")
            prepared = prepare_cleanup(store, path)
            if prepared["status"] != "registered-runs-ended":
                return prepared
            with DirectoryHandle(path):
                plan = _new_plan(store, path, generation, archive)
        if (plan.get("type") != "retirement-planned"
                or plan.get("generation_id") != generation
                or (plan["source"], plan["repo"], plan["base"], plan["output_root"])
                != (str(path), repo, base, str(root))):
            raise StoreConflict("retirement-parameters-changed")
        return _finish(store, path, generation, plan, root)
