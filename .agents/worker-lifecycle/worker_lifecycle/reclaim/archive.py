# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Stage 2 of the reclaim sweep: archive, verify, then remove (GH#38394).

Runs only after stage 1 has judged every candidate in the pass, and only for
``archive`` decisions: finished work whose owners have all ended but whose local
state (uncommitted changes or unpushed commits) removal would discard.

Each tree is archived with ``worktree-archive-helper.sh archive --bundle-commits``,
so the archive carries its own commits and depends only on its base on the
default branch, never on a remote branch the merge flow deletes (#38056). The
archive must pass ``verify-local`` and is journaled as ``reclaim-archived`` with
its id (path and manifest sha256) before removal. Removal then requires the
judgement-time evidence fingerprint to be unchanged and ``source-matches`` to
confirm the archive is still a faithful copy. Any failure keeps the tree, and a
verified archive is kept either way.
"""

from __future__ import annotations

from collections.abc import Callable
import hashlib
import os
from pathlib import Path
import subprocess  # nosec B404 -- exception types only; no process is started here.
from typing import TYPE_CHECKING

from ..archive_path import create_archive_root, validate_archive_path
from ..filesystem import FilesystemValidationError
from ..preservation import run_helper
from .decision import ARCHIVED, REMOVED, cas_verify, record
from .host import common_directory, git, remove
from .progress import remember

if TYPE_CHECKING:
    from ..storage import LifecycleRegistry
    from .sweep import Pass

__all__ = ["MIN_SECONDS", "archive_root", "stage_two"]

# Never start an archive the remaining pass budget cannot plausibly cover.
MIN_SECONDS = 30
# Upper bound for one helper call; the pass budget usually binds first.
HELPER_TIMEOUT = 300
SOURCE_CHANGED = "source-changed-since-archive"
BUDGET_EXHAUSTED = "archive-budget-exhausted"

Budget = Callable[[], int]


def archive_root() -> Path:
    """The producer archive root the helper and its retention prune share."""
    configured = os.environ.get("AIDEVOPS_WORKTREE_ARCHIVE_ROOT")
    root = Path(configured) if configured else (
        Path.home() / ".aidevops" / "recovery" / "archives")
    return root.absolute()


def _attribution(verdict: dict) -> list[str]:
    """Attribute the archive to the tree's issue, or record it as unattributed."""
    issues = [reference[2:] for reference in verdict.get("references", [])
              if reference.startswith("gh") and reference[2:].isdigit()]
    if issues:
        return ["--reason", "post-pr-cleanup", "--issue", issues[0]]
    return ["--unattributed", "--reason", "unattributed-worktree"]


def _base_branch(path: Path, timeout: int) -> str | None:
    status, ref = git(path, "symbolic-ref", "--short", "refs/remotes/origin/HEAD",
                      timeout=timeout)
    prefix = "origin/"
    if status != 0 or not ref.startswith(prefix) or len(ref) == len(prefix):
        return None
    return ref[len(prefix):]


def _timeout(remaining: Budget) -> int:
    return max(min(remaining(), HELPER_TIMEOUT), 1)


def _failure(error: BaseException, default: str) -> str:
    """Name a helper failure; only ``ARCHIVE_FAILURES`` are ever deferred."""
    if isinstance(error, subprocess.TimeoutExpired):
        return "archive-timeout"
    stderr = getattr(error, "stderr", None)
    if isinstance(stderr, bytes) and b"insufficient-capacity" in stderr:
        return "archive-capacity"
    return default


def _archive_base(path: Path, remaining: Budget) -> tuple[str | None, str]:
    """The archive's base branch, or None and why no archive may start."""
    branch = _base_branch(path, _timeout(remaining))
    if branch is None:
        return None, "archive-base-unknown"
    # The base lookup spends budget too; recheck before starting the archive.
    if remaining() < MIN_SECONDS:
        return None, BUDGET_EXHAUSTED
    return branch, ""


def capture(path: Path, verdict: dict, root: Path, remaining: Budget) -> tuple[Path | None, str]:
    """Create and locally verify one archive; return it, or None and the reason."""
    branch, refused = _archive_base(path, remaining)
    if branch is None:
        return None, refused
    try:
        create_archive_root(root)
        root = root.resolve(strict=True)
        validate_archive_path(root)
        output = run_helper(
            "archive", str(path), "--repo", str(verdict["repository"]),
            *_attribution(verdict), "--base-branch", branch,
            "--output-root", str(root), "--bundle-commits", timeout=_timeout(remaining))
    except (subprocess.SubprocessError, OSError, ValueError, FilesystemValidationError) as error:
        return None, _failure(error, "archive-failed")
    archive = Path(output.strip())
    try:
        if (not archive.is_absolute() or archive.resolve(strict=True) != archive
                or not archive.is_relative_to(root)):
            return None, "archive-failed"
        validate_archive_path(root, archive)
        run_helper("verify-local", str(archive), timeout=_timeout(remaining))
    except (subprocess.SubprocessError, OSError, ValueError, FilesystemValidationError) as error:
        return None, _failure(error, "archive-verify-failed")
    return archive, "archive-verified"


def archive_id(archive: Path) -> dict:
    """Name an archive by path and manifest digest, the journaled archive id."""
    manifest = (archive / "manifest.json").read_bytes()
    return {"path": str(archive), "manifest_sha256": hashlib.sha256(manifest).hexdigest()}


def source_matches(archive: Path, remaining: Budget) -> Callable[[Path], tuple[bool, str]]:
    """Removal-time verifier: the tree must still equal what was archived."""
    def check(target: Path) -> tuple[bool, str]:
        try:
            run_helper("source-matches", str(archive), str(target),
                       timeout=_timeout(remaining))
        except (subprocess.SubprocessError, OSError, ValueError):
            return False, SOURCE_CHANGED
        return True, "archived"
    return check


def _preserve(path: Path, verdict: dict, digest: str, remaining: Budget,
              store: LifecycleRegistry) -> tuple[Path, dict] | None:
    """Archive, verify and journal one tree; on failure name why in ``removal``."""
    archive, detail = capture(path, verdict, archive_root(), remaining)
    blocked = detail if archive is None else None
    if archive is not None:
        try:
            verdict["archive"] = archive_id(archive)
        except OSError:
            # A verified archive whose manifest cannot be read fails this tree
            # only; the sweep goes on to the rest of the queue.
            verdict["removal"] = "archive-verify-failed"
            return None
        blocked = record(store, ARCHIVED, verdict, digest, archive=verdict["archive"])
    if blocked is not None or archive is None:
        verdict["removal"] = blocked
        return None
    return archive, verdict["archive"]


def _archive_and_remove(path: Path, verdict: dict, current: Pass, receipt: dict,
                        store: LifecycleRegistry) -> Path | None:
    """Archive, journal and remove one tree; return its repository on removal."""
    digest = verdict.get("fingerprint")
    owner = current.owner
    preserved = None
    if owner is None or digest is None:
        verdict["removal"] = ("owner-observation-unavailable" if owner is None
                              else "fingerprint-unavailable")
    else:
        preserved = _preserve(path, verdict, digest, current.remaining, store)
    if preserved is None or owner is None or digest is None:
        return None
    archive, identity = preserved
    receipt["archived"] += 1
    common = common_directory(path)
    verify = cas_verify(digest, source_matches(archive, current.remaining), current.remaining)
    removed, verdict["removal"] = remove(path, verify, owner)
    if not removed:
        return None
    unrecorded = record(store, REMOVED, verdict, digest, archive=identity)
    if unrecorded is not None:
        verdict["journal"] = unrecorded
    return common


def stage_two(queued: list[tuple[Path, dict]], current: Pass, receipt: dict) -> set[Path]:
    """Archive then remove every queued tree the budget allows, in queue order.

    Applied passes with observed owners only; a dry run leaves the queue as
    ``archive_queued`` and writes nothing. Trees the budget cannot reach are
    re-judged on a later pass. Returns repositories needing a worktree prune.
    """
    store: LifecycleRegistry | None = getattr(current.owner, "store", None)
    repositories: set[Path] = set()
    if not current.apply_removal or current.owner is None or store is None:
        return repositories
    for path, verdict in queued:
        if current.remaining() < MIN_SECONDS:
            receipt["budget_exhausted"] = True
            verdict["removal"] = BUDGET_EXHAUSTED
            continue
        common = _archive_and_remove(path, verdict, current, receipt, store)
        if verdict.get("removal") == BUDGET_EXHAUSTED:
            receipt["budget_exhausted"] = True
            continue
        if common is None:
            receipt["failed"] += 1
        else:
            receipt["removed"] += 1
            repositories.add(common)
        remember(current.quarantine, path, verdict)
    return repositories
