# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Host observation and removal mechanics for the finished-worktree reclaim pass.

Every reader here reports unavailability rather than an optimistic default: an
unreadable process census is not an absence of writers.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
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


@dataclass(frozen=True)
class Census:
    """One process observation: working directories, arguments, and its own gaps.

    ``unplaceable`` counts live same-user processes whose working directory could
    not be read. Those processes are still matched by argument, but they remain a
    reported gap rather than an assumed absence.
    """

    directories: frozenset[Path]
    arguments: tuple[str, ...]
    unplaceable: int = 0

    def holds(self, path: Path) -> bool:
        """Report whether any observed process works in, or names, this worktree."""
        if any(directory == path or path in directory.parents
               for directory in self.directories):
            return True
        return any(str(path) in argument for argument in self.arguments)


def _environment() -> dict[str, str]:
    return {name: value for name, value in os.environ.items()
            if name not in GIT_REDIRECTS}


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


def _arguments(entry: Path) -> list[str]:
    try:
        return (entry / "cmdline").read_bytes().decode("utf-8", "replace").split("\0")
    except OSError:
        return []


def _live_same_user(entry: Path, uid: int) -> bool:
    try:
        return entry.stat().st_uid == uid
    except OSError:
        return False


def process_census() -> Census | None:
    """Observe every readable process, or None when the census cannot be trusted."""
    procfs = Path("/proc")
    if not procfs.is_dir():
        return None
    uid = os.getuid()
    directories: set[Path] = set()
    arguments: list[str] = []
    unplaceable = 0
    for entry in procfs.iterdir():
        if not entry.name.isdigit():
            continue
        arguments.extend(argument for argument in _arguments(entry) if argument)
        try:
            directories.add(Path(os.readlink(entry / "cwd")))
        except OSError:
            # Exited processes are harmless; a live same-user process we cannot
            # place stays a reported gap, matched only by its arguments.
            unplaceable += 1 if _live_same_user(entry, uid) else 0
    if Path.cwd() not in directories:
        return None
    return Census(frozenset(directories), tuple(arguments), unplaceable)


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


def _removal_blocked(path: Path, verify: Callable[[Path], tuple[bool, str]]) -> str | None:
    """Re-check liveness and state at the last moment, naming the first blocker."""
    census = process_census()
    if census is None:
        return "process-inventory-unavailable"
    # Identity first: repository state means nothing until the path is known to be
    # a removable linked worktree.
    identity = ((census.holds(path), "writers-appeared"),
                (metadata_directory(path) is None, "not-a-linked-worktree"),
                (locked(path), "worktree-locked"))
    blocked = next((reason for failed, reason in identity if failed), None)
    if blocked is not None:
        return blocked
    clean, detail = verify(path)
    return None if clean else f"changed-{detail}"


def remove(path: Path, verify: Callable[[Path], tuple[bool, str]]) -> tuple[bool, str]:
    """Remove one worktree, re-verifying liveness and state immediately first.

    ``verify`` re-runs the caller's state checks, so an edit landing between
    judgement and deletion still refuses. Forced removal is retained because
    ignored build artifacts are expected and Git refuses them otherwise; it is
    reached only after a fresh clean verdict.
    """
    blocked = _removal_blocked(path, verify)
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
