"""Verify a WIP archive for a closed generation without removing the source."""

from collections.abc import Iterator
from contextlib import contextmanager
from contextvars import ContextVar
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess  # nosec B404 # fixed local helper programs, explicit argv
import sys
import tempfile
from uuid import UUID, uuid5

from .cleanup_plan import prepare_cleanup
from .enrollment import _git_directory
from .storage import LifecycleRegistry, StoreConflict, _private, encode


SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
_OPERATION_LOCKS: ContextVar[tuple[int, ...]] = ContextVar("operation_locks", default=())


@contextmanager
def inherit_operation_lock(descriptor: int) -> Iterator[None]:
    """Keep the operation locked while its explicit helper survives its caller."""
    token = _OPERATION_LOCKS.set((*_OPERATION_LOCKS.get(), descriptor))
    try:
        yield
    finally:
        _OPERATION_LOCKS.reset(token)


def _run(command: list[str]) -> str:
    environment = {
        name: value for name, value in os.environ.items()
        if not name.startswith("GIT_")
    }
    environment.update(
        GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0",
        AIDEVOPS_WORKTREE_RECOVERY_POLICY="git-only",
        PYTHONDONTWRITEBYTECODE="1",
    )
    result = subprocess.run(  # nosec B603 # local helpers and literal path arguments
        command, env=environment, capture_output=True, check=True, timeout=120,
        pass_fds=_OPERATION_LOCKS.get(),
    )
    return os.fsdecode(result.stdout).removesuffix("\n")


def _snapshot(path: Path) -> dict:
    return json.loads(_run([
        sys.executable, "-E", "-s", "-B",
        str(SCRIPTS / "worktree_archive_snapshot.py"), "--git-only", str(path),
    ]))


def _helper(*arguments: str) -> str:
    bash = shutil.which("bash")
    if bash is None:
        raise ValueError("archive-bash-unavailable")
    return _run([bash, str(SCRIPTS / "worktree-archive-helper.sh"), *arguments])


def _retain_base(path: Path, operation: str, base: str) -> str:
    git = shutil.which("git")
    if git is None:
        raise ValueError("archive-git-unavailable")
    reference = f"refs/aidevops/wip-base/{operation}"
    command = [git, "-C", str(path)]
    try:
        _run([*command, "update-ref", reference, base, "0" * len(base)])
    except subprocess.CalledProcessError:
        # A retry may find its own pin, but must never overwrite another value.
        if _run([*command, "rev-parse", "--verify", reference]) != base:
            raise StoreConflict("archive-base-reference-conflict") from None
    return reference


def verify_restoration(archive: Path, root: Path, snapshot: dict) -> dict:
    """Verify archive contents independently of the source's current pathname."""
    if archive.resolve(strict=True) != archive or not archive.is_relative_to(root):
        raise ValueError("archive-outside-private-output-root")
    _private(archive, directory=True)
    _helper("verify", str(archive))
    manifest = json.loads((archive / "manifest.json").read_bytes())
    if (manifest.get("capture_policy") != "git-only"
            or manifest.get("include_ignored", False) is not False
            or manifest.get("source_fingerprint") != snapshot):
        raise ValueError("archive-policy-or-content-mismatch")
    with tempfile.TemporaryDirectory(prefix=".verify-wip-", dir=root) as temporary:
        restored = Path(temporary) / "tree"
        _helper("restore", str(archive), "--target", str(restored),
                "--verification-copy")
        if _snapshot(restored) != snapshot:
            raise ValueError("restored-wip-does-not-match-source")
    return manifest


def _verify(archive: Path, path: Path, root: Path, snapshot: dict) -> dict:
    manifest = verify_restoration(archive, root, snapshot)
    _helper("source-matches", str(archive), str(path))
    return manifest


def preserve_wip(
    store: LifecycleRegistry, path: Path, repo: str, base_branch: str, root: Path,
) -> dict[str, object]:
    """Close, archive and compare restoration; ignored files remain excluded.

    Receipts describe the current common repository dependency, not a standalone
    backup or removal authority. Replays verify the existing archive again.
    """
    if not root.is_absolute() or root.resolve(strict=True) != root:
        raise ValueError("canonical-output-root-required")
    _private(root, directory=True)
    if root.is_relative_to(path) or root.is_relative_to(_git_directory(path)):
        raise ValueError("archive-output-must-be-outside-worktree")
    prepared = prepare_cleanup(store, path)
    if prepared["status"] != "registered-runs-ended":
        return prepared
    generation = str(prepared["generation_id"])
    snapshot = _snapshot(path)
    operation = str(uuid5(UUID(generation), encode({
        "type": "preserve-wip", "snapshot": snapshot, "repo": repo,
        "base_branch": base_branch, "output_root": str(root),
    })))
    with store.connection() as connection:
        row = connection.execute(
            "SELECT payload FROM events WHERE event_id=?", (operation,),
        ).fetchone()
    previous = json.loads(row["payload"]) if row else None
    archive = Path(previous["archive"]) if previous else Path(_helper(
        "archive", str(path), "--repo", repo, "--unattributed",
        "--reason", "unattributed-worktree", "--base-branch", base_branch,
        "--output-root", str(root),
    ))
    manifest = _verify(archive, path, root, snapshot)
    base_reference = _retain_base(path, operation, manifest["base_sha"])
    current = prepare_cleanup(store, path)
    if (current["generation_id"] != generation
            or current["status"] != "registered-runs-ended"):
        raise StoreConflict("registered-runs-changed-during-preservation")
    receipt = {
        "type": "wip-preserved", "generation_id": generation,
        "archive": str(archive), "snapshot": snapshot,
        "manifest_sha256": hashlib.sha256(
            (archive / "manifest.json").read_bytes()).hexdigest(),
        "base_sha": manifest["base_sha"], "base_ref": base_reference,
        "common_repository_required": True,
    }
    with store.connection(write=True) as connection:
        store._event(connection, operation, receipt)
    return dict(current, status="wip-archive-verified", archive=str(archive),
                common_repository_required=True, operation_id=operation,
                base_ref=base_reference)
