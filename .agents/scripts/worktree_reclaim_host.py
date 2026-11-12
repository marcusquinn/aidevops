#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Host observation and removal mechanics for the finished-worktree reclaim pass.

Every reader here reports unavailability rather than an optimistic default: an
unreadable process census is not an absence of writers.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess  # nosec B404 -- fixed git and gh invocations only.


def run(command: list[str], timeout: int = 60) -> tuple[int, str]:
    """Return the exit status and stripped stdout, never raising on failure."""
    try:
        completed = subprocess.run(  # nosec B603 -- argument vector, no shell.
            command, capture_output=True, text=True, timeout=timeout, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return 1, ""
    return completed.returncode, completed.stdout.strip()


def git(path: Path, *arguments: str) -> tuple[int, str]:
    return run(["git", "-C", str(path), *arguments])


def working_directories() -> set[Path] | None:
    """Resolve every readable process working directory, or None when unknowable."""
    procfs = Path("/proc")
    if not procfs.is_dir():
        return None
    directories: set[Path] = set()
    for entry in procfs.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            directories.add(Path(os.readlink(entry / "cwd")))
        except OSError:
            # A process exiting mid-scan cannot hold a worktree we then delete,
            # and a census that cannot see itself is rejected below.
            continue
    return directories if Path.cwd() in directories else None


def occupied(path: Path, census: set[Path]) -> bool:
    """Report whether any observed process works in the worktree or inside it."""
    return any(directory == path or path in directory.parents for directory in census)


def remove(path: Path) -> tuple[bool, str]:
    """Remove one worktree, re-checking liveness immediately before deleting."""
    census = working_directories()
    if census is None:
        return False, "process-inventory-unavailable"
    if occupied(path, census):
        return False, "writers-appeared"
    status, _ = git(path, "worktree", "remove", "--force", str(path))
    if status != 0 and path.exists():
        try:
            shutil.rmtree(path)
        except OSError as error:
            return False, f"removal-failed-{error.errno}"
    return (not path.exists()), ("removed" if not path.exists() else "removal-incomplete")


def directory_size(path: Path) -> int:
    total = 0
    for root, _, files in os.walk(path, onerror=lambda _: None):
        for name in files:
            try:
                total += (Path(root) / name).stat(follow_symlinks=False).st_size
            except OSError:
                continue
    return total


def common_directory(path: Path) -> Path | None:
    """Resolve the repository whose worktree metadata needs pruning after removal."""
    status, common = git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")
    return Path(common) if status == 0 and common else None
