"""Archive-first retirement of copied foreign-generation worktrees (GH#37828).

A worktree restored from another host keeps a marker of another installation, so
normal cleanup refuses it as `generation-directory-mismatch`. This path retires
it only with proof that its work lives elsewhere (see `foreign_proof`). The
source is archived through the normal preservation helpers first, relocated by
Git and removed by the shared journaled removal. The marker is never rewritten,
admission is never opened and no registry authority is granted.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import tempfile
from uuid import UUID, uuid5

from .archive_path import validate_archive_path
from .cleanup_plan import foreign_marker, require_foreign_unregistered
from .directory_handle import DirectoryHandle
from .enrollment import _directory_inode
from .filesystem import validate_private_path as _private
from .foreign_proof import RECEIPT, prove, require_foreign_identity
from .legacy_proc import require_idle_processes
from .preservation import _helper, _retain_base, _snapshot, _verify
from .retirement import (
    ArchiveTarget, _event, _event_id, _git, _lock, _preserved, _remove_private,
)
from .retirement_fence import release_path, reserve
from .storage import LifecycleRegistry, StoreConflict, encode

__all__ = ["RECEIPT", "retire_foreign_worktree"]


def _preserve(
    store: LifecycleRegistry, path: Path, found: dict, archive: ArchiveTarget,
) -> dict:
    """Archive and verify through the shared helpers; the receipt grants nothing."""
    generation, root = found["generation_id"], archive.root
    if root.is_relative_to(path) or root.is_relative_to(found["admin"]):
        raise ValueError("archive-output-must-be-outside-worktree")
    snapshot = _snapshot(path)
    operation = str(uuid5(UUID(generation), encode({
        "type": "preserve-foreign-wip", "snapshot": snapshot, "repo": archive.repository,
        "base_branch": archive.base_branch, "output_root": str(root),
    })))
    previous = _event(store, operation)
    directory = Path(previous["archive"]) if previous else Path(_helper(
        "archive", str(path), "--repo", archive.repository, "--unattributed",
        "--reason", "unattributed-worktree", "--base-branch", archive.base_branch,
        "--output-root", str(root),
    ))
    manifest = _verify(directory, path, root, snapshot)
    reference = _retain_base(path, operation, manifest["base_sha"])
    receipt = {
        "type": "wip-preserved", "generation_id": generation, "archive": str(directory),
        "snapshot": snapshot,
        "manifest_sha256": hashlib.sha256(
            (directory / "manifest.json").read_bytes()).hexdigest(),
        "base_sha": manifest["base_sha"], "base_ref": reference,
        "common_repository_required": True,
    }
    if previous is None:
        with store.connection(write=True) as connection:
            store._event(connection, operation, receipt)
    return {"operation": operation, "receipt": receipt}


def _new_plan(
    store: LifecycleRegistry, path: Path, found: dict, archive: ArchiveTarget,
    proof: dict[str, str],
) -> dict:
    generation = found["generation_id"]
    preserved = _preserve(store, path, found, archive)
    container = Path(tempfile.mkdtemp(prefix=".lifecycle-retire-", dir=path.parent))
    admin, common = found["admin"], found["common"]
    plan = {
        "type": "foreign-retirement-planned", "generation_id": generation,
        "source": str(path), "repo": archive.repository, "base": archive.base_branch,
        "output_root": str(archive.root), "container": str(container),
        "container_identity": _directory_inode(container),
        "directory_identity": _directory_inode(path), "git_directory": str(admin),
        "git_identity": _directory_inode(admin), "common": str(common),
        "common_identity": _directory_inode(common),
        "preservation_id": preserved["operation"],
        "marker_sha256": found["marker_sha256"], "proof": proof,
    }
    # Fence and plan commit together: no writer can slip in between them.
    with store.connection(write=True) as connection:
        reserve(connection, generation, str(path))
        store._event(connection, _event_id(generation, "planned"), plan)
    return plan


def _unchanged(path: Path, plan: dict, receipt: dict, found: dict) -> bool:
    return (found["generation_id"] == plan["generation_id"]
            and found["marker_sha256"] == plan["marker_sha256"]
            and _directory_inode(path) == plan["directory_identity"]
            and _snapshot(path) == receipt["snapshot"])


def _relocate(store: LifecycleRegistry, path: Path, plan: dict, receipt: dict) -> None:
    require_idle_processes(path)
    with DirectoryHandle(path) as original:
        found = foreign_marker(store, path)
        if not _unchanged(path, plan, receipt, found) or not original.matches_path():
            raise StoreConflict("source-changed-before-relocation")
        # Proof is re-run now, not trusted from planning time: remotes and the
        # rescue destination can change between an interrupted run and its resume.
        bundle = plan["proof"].get("bundle")
        prove(path, Path(bundle) if bundle else None)
        # No force: Git locks and unsupported moves must stop the operation.
        _git("--git-dir", plan["common"], "worktree", "move", str(path),
             str(Path(plan["container"]) / "tree"))


def _require_container(path: Path, plan: dict) -> Path:
    """Bind the owned private container to the plan; return it."""
    container = Path(plan["container"])
    if (container.parent != path.parent
            or not container.name.startswith(".lifecycle-retire-")
            or container.resolve(strict=True) != container
            or _directory_inode(container) != plan["container_identity"]):
        raise StoreConflict("retirement-container-changed")
    _private(container, directory=True)
    return container


def _remove_tree(
    store: LifecycleRegistry, path: Path, plan: dict, receipt: dict, container: Path,
) -> None:
    """Relocate (first run) and remove the private tree; fail closed otherwise."""
    generation = plan["generation_id"]
    target, admin = container / "tree", Path(plan["git_directory"])
    removing = _event(store, _event_id(generation, "removing"))
    if not os.path.lexists(target) and removing is None:
        _relocate(store, path, plan, receipt)
    if os.path.lexists(target):
        require_foreign_unregistered(store, path, generation)
        if removing is None:
            # Resumed after relocation: revalidate proof against the moved tree first.
            bundle = plan["proof"].get("bundle")
            prove(target, Path(bundle) if bundle else None, path)
        _remove_private(store, path, plan, receipt, require_foreign_identity)
    elif removing is None or os.path.lexists(admin):
        raise StoreConflict("retirement-outcome-unverified")
    if os.path.lexists(target):
        raise StoreConflict("private-worktree-still-present")


def _finish(
    store: LifecycleRegistry, path: Path, generation: str, plan: dict, root: Path,
) -> dict[str, object]:
    receipt = _preserved(store, plan, root)
    result: dict[str, object] = {
        "generation_id": generation, "status": "retired", "foreign_generation": True,
        "archive": receipt["archive"], "common_repository_required": True,
        "cleanup_authorized": False,
    }
    if _event(store, _event_id(generation, "retired")) is not None:
        return result
    container = _require_container(path, plan)
    _remove_tree(store, path, plan, receipt, container)
    with store.connection(write=True) as connection:
        store._event(connection, _event_id(generation, "retired"), {
            "type": "foreign-worktree-retired", "generation_id": generation,
            "preservation_id": plan["preservation_id"],
        })
        release_path(connection, generation)
    try:
        container.rmdir()  # Empty owned container only; never recursive cleanup.
    except OSError:
        result["container_cleanup_pending"] = True
    return result


def _plan_matches(plan: dict, path: Path, archive: ArchiveTarget, generation: str) -> bool:
    return (plan.get("type") == "foreign-retirement-planned"
            and plan.get("generation_id") == generation
            and (plan["source"], plan["repo"], plan["base"], plan["output_root"])
            == (str(path), archive.repository, archive.base_branch, str(archive.root)))


def _locate(
    store: LifecycleRegistry, path: Path, generation: str | None,
) -> tuple[str, dict | None]:
    """Resolve the generation and, for a first run, the foreign marker evidence."""
    if generation is not None:
        generation = str(UUID(generation))
    # A supplied generation resumes its saved plan before the public path is
    # inspected, so a replacement now occupying that path is never classified.
    saved = _event(store, _event_id(generation, "planned")) if generation else None
    found = None
    if saved is None and os.path.lexists(path):
        found = foreign_marker(store, path)
        if path.resolve(strict=True) != path:
            raise ValueError("canonical-source-required")
        found_generation = str(found["generation_id"])
        if generation is not None and found_generation != generation:
            raise StoreConflict("retirement-generation-mismatch")
        generation = found_generation
    if generation is None:
        raise StoreConflict("foreign-source-absent")
    return generation, found


def retire_foreign_worktree(
    store: LifecycleRegistry, path: Path, archive: ArchiveTarget,
    bundle: Path | None = None, generation: str | None = None,
) -> dict[str, object]:
    """Retire a foreign-generation tree after proof and a verified archive.

    `generation` is needed only to resume after the source was relocated.
    """
    root = archive.root
    if not path.is_absolute() or path.parent.resolve(strict=True) != path.parent:
        raise ValueError("canonical-source-parent-required")
    if not root.is_absolute() or root.resolve(strict=True) != root:
        raise ValueError("canonical-output-root-required")
    validate_archive_path(root)
    generation, found = _locate(store, path, generation)
    with _lock(store, generation):
        plan = _event(store, _event_id(generation, "planned"))
        if plan is None:
            if found is None:
                raise StoreConflict("foreign-source-absent")
            proof = {**prove(path, bundle), "bundle": str(bundle or "")}
            require_idle_processes(path)
            with DirectoryHandle(path):
                plan = _new_plan(store, path, found, archive, proof)
        if not _plan_matches(plan, path, archive, generation):
            raise StoreConflict("retirement-parameters-changed")
        if _event(store, _event_id(generation, "retired")) is None:
            with store.connection(write=True) as connection:
                reserve(connection, generation, plan["source"])  # Idempotent on resume.
        return _finish(store, path, generation, plan, root)
