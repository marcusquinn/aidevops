"""Archive-first retirement of copied foreign-generation worktrees (GH#37828).

A worktree restored from another host keeps a marker of another installation, so
normal cleanup refuses it as `generation-directory-mismatch`. This path retires
it only with proof that its work lives elsewhere: a verified rescue receipt whose
hashes still match the source, or a clean tree whose HEAD is on a pushed ref. The
source is archived through the normal preservation helpers first, relocated by
Git and removed by the shared journaled removal. The marker is never rewritten,
admission is never opened and no registry authority is granted.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shutil
import subprocess  # nosec B404 # fixed read-only Git queries, explicit argv
import tempfile
from uuid import UUID, uuid5

from .archive_path import validate_archive_path
from .cleanup_plan import foreign_marker
from .directory_handle import DirectoryHandle
from .enrollment import _directory_inode
from .filesystem import validate_private_path as _private
from .legacy_proc import require_idle_processes
from .preservation import _helper, _retain_base, _snapshot, _verify
from .retirement import (
    ArchiveTarget, _event, _event_id, _git, _lock, _preserved, _record, _remove_private,
)
from .storage import LifecycleRegistry, StoreConflict, encode

RECEIPT = "receipt.txt"
DIFF_ARGS = (
    "diff", "--binary", "--full-index", "--no-color", "--no-ext-diff", "--no-textconv",
    "--no-renames", "--diff-algorithm=myers", "--no-indent-heuristic",
    "--src-prefix=a/", "--dst-prefix=b/", "HEAD",
)
STATE_MARKERS = (
    "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply",
    "BISECT_LOG",
)


def _read_git(path: Path, *arguments: str) -> bytes:
    """Run read-only native Git on the source without optional index refreshes."""
    git = shutil.which("git")
    if git is None:
        raise ValueError("archive-git-unavailable")
    environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    environment.update(GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")
    return subprocess.run(  # nosec B603 # resolved git, literal flags, path as one argv item
        [git, "--no-optional-locks", "-C", str(path), *arguments],
        env=environment, capture_output=True, check=True, timeout=120, shell=False,
    ).stdout


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def source_hashes(path: Path) -> dict[str, str]:
    """Reproduce the rescue helper's patch and untracked-file hashes for `path`."""
    listing = _read_git(path, "ls-files", "--others", "--exclude-standard", "-z")
    records = bytearray()
    for raw in listing.split(b"\0")[:-1] if listing else []:
        name = os.fsdecode(raw)
        entry = path / name.rstrip("/")
        if name.endswith("/") or (entry.is_dir() and not entry.is_symlink()):
            raise StoreConflict("untracked-directory-unsupported")
        digest = (b"link:" + os.fsencode(os.readlink(entry)) if entry.is_symlink()
                  else f"sha256:{_sha(entry.read_bytes())}".encode())
        records += digest + b"\t" + raw.rstrip(b"/") + b"\0"
    return {
        "head": _read_git(path, "rev-parse", "HEAD").decode().strip(),
        "patch_sha256": _sha(_read_git(path, *DIFF_ARGS)),
        "untracked_hashes_sha256": _sha(bytes(records)),
        "untracked_list_sha256": _sha(listing),
    }


def _in_progress(path: Path) -> bool:
    admin = Path(_read_git(path, "rev-parse", "--absolute-git-dir").decode().strip())
    return any(os.path.lexists(admin / name) for name in STATE_MARKERS)


def _key_values(file: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    if file.is_symlink() or not file.is_file() or file.stat().st_size > 65536:
        raise StoreConflict("rescue-receipt-unavailable")
    for line in file.read_text(encoding="utf-8").splitlines():
        key, separator, value = line.partition("=")
        if not separator or key in result:
            raise StoreConflict("rescue-receipt-invalid")
        result[key] = value
    return result


def _rescue_proof(path: Path, bundle: Path, current: dict[str, str]) -> dict[str, str]:
    """Require the bundle, its verify receipt and the source to agree exactly."""
    if bundle.resolve(strict=True) != bundle or bundle.is_relative_to(path):
        raise StoreConflict("rescue-bundle-must-be-outside-source")
    manifest, receipt = _key_values(bundle / "manifest.txt"), _key_values(bundle / RECEIPT)
    if manifest.get("format") != "1" or receipt.get("format") != "1":
        raise StoreConflict("rescue-format-unsupported")
    if receipt.get("bundle_manifest_sha256") != _sha((bundle / "manifest.txt").read_bytes()):
        raise StoreConflict("rescue-receipt-manifest-mismatch")
    patch = bundle / "changes.patch"
    if patch.is_symlink() or _sha(patch.read_bytes()) != manifest.get("patch_sha256"):
        raise StoreConflict("rescue-bundle-corrupt")
    for name in ("source", "head", "patch_sha256", "untracked_hashes_sha256",
                 "untracked_list_sha256"):
        if receipt.get(name) != manifest.get(name):
            raise StoreConflict("rescue-receipt-manifest-mismatch")
    if manifest["source"] != str(path):
        raise StoreConflict("rescue-receipt-other-source")
    for name, value in current.items():
        if manifest.get(name) != value:
            raise StoreConflict("source-changed-since-rescue")
    return {"kind": "rescue-receipt", "manifest_sha256": receipt["bundle_manifest_sha256"],
            "destination": receipt.get("verified_destination", "")}


def _pushed_proof(path: Path, head: str) -> dict[str, str]:
    """A clean tree whose HEAD any remote-tracking ref already contains."""
    if _read_git(path, "status", "--porcelain", "--untracked-files=all"):
        raise StoreConflict("rescue-or-clean-pushed-proof-required")
    refs = _read_git(path, "for-each-ref", "--format=%(refname)", "--contains", head,
                     "refs/remotes/").decode().split()
    if not [ref for ref in refs if not ref.endswith("/HEAD")]:
        raise StoreConflict("head-not-reachable-from-pushed-ref")
    return {"kind": "pushed-head", "head": head}


def _prove(path: Path, bundle: Path | None) -> dict[str, str]:
    if _in_progress(path):
        raise StoreConflict("source-operation-in-progress")
    current = source_hashes(path)
    if bundle is None:
        return _pushed_proof(path, current["head"])
    return _rescue_proof(path, bundle, current)


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
    _record(store, generation, "planned", plan)
    return plan


def _relocate(store: LifecycleRegistry, path: Path, plan: dict, receipt: dict) -> None:
    require_idle_processes(path)
    with DirectoryHandle(path) as original:
        found = foreign_marker(store, path)
        if (found["generation_id"] != plan["generation_id"]
                or found["marker_sha256"] != plan["marker_sha256"]
                or _directory_inode(path) != plan["directory_identity"]
                or _snapshot(path) != receipt["snapshot"]
                or not original.matches_path()):
            raise StoreConflict("source-changed-before-relocation")
        # No force: Git locks and unsupported moves must stop the operation.
        _git("--git-dir", plan["common"], "worktree", "move", str(path),
             str(Path(plan["container"]) / "tree"))


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
    container = Path(plan["container"])
    if (container.parent != path.parent
            or not container.name.startswith(".lifecycle-retire-")
            or container.resolve(strict=True) != container
            or _directory_inode(container) != plan["container_identity"]):
        raise StoreConflict("retirement-container-changed")
    _private(container, directory=True)
    target, admin = container / "tree", Path(plan["git_directory"])
    removing = _event(store, _event_id(generation, "removing"))
    if not os.path.lexists(target) and removing is None:
        _relocate(store, path, plan, receipt)
    if os.path.lexists(target):
        _remove_private(store, path, plan, receipt)
    elif removing is None or os.path.lexists(admin):
        raise StoreConflict("retirement-outcome-unverified")
    if os.path.lexists(target):
        raise StoreConflict("private-worktree-still-present")
    _record(store, generation, "retired", {
        "type": "foreign-worktree-retired", "generation_id": generation,
        "preservation_id": plan["preservation_id"],
    })
    try:
        container.rmdir()  # Empty owned container only; never recursive cleanup.
    except OSError:
        result["container_cleanup_pending"] = True
    return result


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
    found = foreign_marker(store, path) if os.path.lexists(path) else None
    if found is not None:
        if path.resolve(strict=True) != path:
            raise ValueError("canonical-source-required")
        generation = str(found["generation_id"])
    if generation is None:
        raise StoreConflict("foreign-source-absent")
    generation = str(UUID(generation))
    with _lock(store, generation):
        plan = _event(store, _event_id(generation, "planned"))
        if plan is None:
            if found is None:
                raise StoreConflict("foreign-source-absent")
            proof = _prove(path, bundle)
            require_idle_processes(path)
            with DirectoryHandle(path):
                plan = _new_plan(store, path, found, archive, proof)
        if (plan.get("type") != "foreign-retirement-planned"
                or plan.get("generation_id") != generation
                or (plan["source"], plan["repo"], plan["base"], plan["output_root"])
                != (str(path), archive.repository, archive.base_branch, str(root))):
            raise StoreConflict("retirement-parameters-changed")
        return _finish(store, path, generation, plan, root)
