# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Host observation and removal mechanics for the finished-worktree reclaim pass.

Every reader here reports unavailability rather than an optimistic default.
Ownership is observed through the lifecycle registry (``reclaim.owners``); this
module scans no host processes.
"""

from __future__ import annotations

from collections.abc import Callable
import os
from pathlib import Path
import shutil
import subprocess  # nosec B404 -- fixed git and gh invocations only.

# Git reads these before -C, so an inherited value would silently redirect every
# repository question at another checkout.
GIT_REDIRECTS = (
    "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_CEILING_DIRECTORIES", "GIT_NAMESPACE",
)


def _environment() -> dict[str, str]:
    # No optional locks: a status refresh would rewrite the index, resetting the
    # idle clock that review worktrees are judged by and racing a live writer.
    environment = {name: value for name, value in os.environ.items()
                   if name not in GIT_REDIRECTS}
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    return environment


def run(command: list[str], timeout: int = 60) -> tuple[int, str]:
    """Return the exit status and stripped stdout, never raising on failure."""
    try:
        completed = subprocess.run(  # nosec B603 -- argument vector, no shell.
            command, capture_output=True, text=True, timeout=max(timeout, 1),
            check=False, env=_environment(),
        )
    except (OSError, subprocess.SubprocessError):
        return 1, ""
    return completed.returncode, completed.stdout.strip()


def git(path: Path, *arguments: str, timeout: int = 60) -> tuple[int, str]:
    return run(["git", "-C", str(path), *arguments], timeout=timeout)


# Marker written by full-loop-helper-merge-cleanup.sh to defer cleanup to a
# supervisor; framework state, not work. Porcelain status of it when untracked.
DEFERRED_MARKER = ".agents/.full-loop-cleanup-deferred"
DEFERRED_MARKER_STATUS = f"?? {DEFERRED_MARKER}"


def nothing_to_lose(path: Path, *, timeout: int = 60) -> tuple[bool, str]:
    """Confirm no uncommitted, untracked, or unpushed work exists in the worktree.

    Untracked and submodule reporting are requested explicitly: repository or
    global configuration can otherwise suppress exactly the files that removal
    would discard. Ignored build artifacts stay excluded and expected.
    """
    status, dirty = git(path, "status", "--porcelain", "-z", "--untracked-files=all",
                        "--ignore-submodules=none", timeout=timeout)
    if status != 0:
        return False, "status-unreadable"
    # Only the untracked deferral marker is framework state; a tracked change to
    # that path reports a different status code and still refuses.
    if any(entry and entry != DEFERRED_MARKER_STATUS for entry in dirty.split("\0")):
        return False, "uncommitted-changes"
    status, unpushed = git(path, "rev-list", "--count", "HEAD", "--not", "--remotes",
                           timeout=timeout)
    if status != 0 or not unpushed.isdigit():
        return False, "unpushed-state-unreadable"
    return (unpushed == "0"), ("nothing-to-lose" if unpushed == "0"
                               else f"unpushed-commits-{unpushed}")


def _registered_worktree(metadata: Path, marker: Path) -> bool:
    """Confirm Git registers this metadata directory as a linked worktree.

    A main checkout created with `--separate-git-dir` has the same `.git` file
    shape, so only the `worktrees/` parent and the back-pointer Git writes there
    distinguish a linked worktree from it.
    """
    if metadata.parent.name != "worktrees":
        return False
    try:
        back = Path((metadata / "gitdir").read_text(encoding="utf-8").strip())
    except OSError:
        return False
    if not back.is_absolute():
        # Git resolves a relative back-pointer against the metadata directory;
        # resolving it against the process directory would refuse a valid worktree.
        back = metadata / back
    return back.resolve() == marker.resolve()


def metadata_directory(path: Path) -> Path | None:
    """Resolve a linked worktree's metadata directory from its `.git` file.

    A main checkout has a `.git` directory, not a file, and is never a candidate.
    """
    marker = path / ".git"
    if not marker.is_file():
        return None
    try:
        content = marker.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    prefix = "gitdir:"
    if not content.startswith(prefix):
        return None
    metadata = Path(content[len(prefix):].strip())
    if not metadata.is_absolute():
        # Git permits a relative pointer; reading it from elsewhere would check
        # the wrong directory for locks and registration.
        metadata = (path / metadata).resolve()
    return metadata if _registered_worktree(metadata, marker) else None


def locked(path: Path) -> bool:
    """Report whether Git holds an explicit lock on this linked worktree."""
    metadata = metadata_directory(path)
    return metadata is not None and (metadata / "locked").exists()


def _removal_blocked(path: Path, verify: Callable[[Path], tuple[bool, str]],
                     owner: Callable[[Path], str | None]) -> str | None:
    """Re-check ownership and state at the last moment, naming the first blocker."""
    # Identity first: ownership and repository state mean nothing until the path
    # is known to be a removable linked worktree.
    identity = ((metadata_directory(path) is None, "not-a-linked-worktree"),
                (locked(path), "worktree-locked"))
    blocked = next((reason for failed, reason in identity if failed), None)
    if blocked is not None:
        return blocked
    reason = owner(path)
    if reason is not None:
        return "owners-appeared" if reason == "owner-alive" else reason
    clean, detail = verify(path)
    return None if clean else f"changed-{detail}"


def remove(path: Path, verify: Callable[[Path], tuple[bool, str]],
           owner: Callable[[Path], str | None]) -> tuple[bool, str]:
    """Remove one worktree, re-verifying ownership and state immediately first.

    ``verify`` re-runs the caller's state checks and ``owner`` re-reads the
    registry, so a run admitted or an edit landing between judgement and
    deletion still refuses. Forced removal is retained because ignored build
    artifacts are expected and Git refuses them otherwise; it is reached only
    after a fresh clean verdict.
    """
    blocked = _removal_blocked(path, verify, owner)
    if blocked is not None:
        return False, blocked
    status, _ = git(path, "worktree", "remove", "--force", str(path))
    if status != 0 and path.exists():
        try:
            shutil.rmtree(path)
        except OSError as error:
            return False, f"removal-failed-{error.errno}"
    return (not path.exists()), ("removed" if not path.exists() else "removal-incomplete")


def free_bytes(path: Path) -> int | None:
    """Report free bytes on the filesystem holding ``path``, or None if unreadable."""
    try:
        stats = os.statvfs(path)
    except OSError:
        return None
    return stats.f_bavail * stats.f_frsize


def common_directory(path: Path) -> Path | None:
    """Resolve the repository whose worktree metadata needs pruning after removal."""
    status, common = git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")
    return Path(common) if status == 0 and common else None
