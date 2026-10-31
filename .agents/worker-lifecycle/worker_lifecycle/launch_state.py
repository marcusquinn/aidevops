"""Resolve launcher registry state without executing or discovering processes."""

from __future__ import annotations

import os
from pathlib import Path
import sqlite3
import subprocess  # nosec B404 # Git exception type only
import time
from uuid import uuid4

from .admission import AdmissionClosed
from .enrollment import GenerationEnrollment, MARKER, _git_directory
from .runtime import adapter_for, require_ready
from .storage import LifecycleRegistry


def initialize_or_open(state_dir: Path) -> LifecycleRegistry:
    """Claim a new directory, or wait briefly for another initializer's commit.

    Existing state is only opened and validated, never repaired or replaced.
    A crashed initializer therefore produces a visible gap, not evidence loss.
    """
    try:
        return LifecycleRegistry.initialize(state_dir)
    except FileExistsError:
        deadline = time.monotonic() + 2
        while True:
            try:
                store = LifecycleRegistry(state_dir)
                store.installation_id()
                return store
            except (OSError, ValueError, sqlite3.Error):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.05)


def enrolled_generation(
    state_dir: Path, worktree: Path, initialize: bool,
) -> tuple[str, Path] | None:
    """Select registered generations, never infer them from legacy bindings.

    A failed lookup cannot establish that admission is unnecessary. Neither an
    unknown nor a known admission may degrade into hypothetical registration.
    """
    require_ready(adapter_for(str(uuid4())))
    store = initialize_or_open(state_dir) if initialize else LifecycleRegistry(state_dir)
    # A declared reservation must not disappear through symlink resolution.
    path = Path(os.path.abspath(worktree))
    with store.connection() as connection:
        if connection.execute("PRAGMA user_version").fetchone()[0] == 1:
            if connection.execute(
                "SELECT 1 FROM sqlite_master WHERE name='generation_admissions'",
            ).fetchone():
                raise ValueError("schema-one-with-admission-state")
            row = None
        else:
            query = (
                "SELECT path FROM generation_admissions "
                "WHERE path=? OR substr(?,1,length(path)+1)=path||'/' "
                "ORDER BY (state='closed') DESC,length(path) DESC LIMIT 1"
            )
            declared = connection.execute(query, (str(path), str(path))).fetchone()
            resolved = str(worktree.resolve(strict=True))
            row = connection.execute(query, (resolved, resolved)).fetchone()
            if declared and (row is None or declared["path"] != row["path"]):
                raise AdmissionClosed("declared-resource-resolution-changed")
            if row is not None:
                path = Path(row["path"])
    if row is None:
        if _has_generation_marker(worktree):
            raise AdmissionClosed("marker-without-matching-registry-admission")
        return None
    try:
        return GenerationEnrollment(store).resolve(path), path
    except (ValueError, OSError, RuntimeError, sqlite3.Error,
            subprocess.SubprocessError) as error:
        raise AdmissionClosed("enrolled-generation-unavailable") from error


def _has_generation_marker(worktree: Path) -> bool:
    path = worktree.resolve(strict=True)
    if not path.is_dir():
        raise ValueError("unregistered-worktree-unavailable")
    for directory in (path, *path.parents):
        if (directory / ".git").is_symlink():
            raise ValueError("unregistered-worktree-unavailable")
        if (directory / ".git").is_file():
            marker = _git_directory(directory) / MARKER
            if marker.exists() or marker.is_symlink():
                return True
    return False


def require_unregistered(state_dir: Path, worktree: Path) -> None:
    """Verify exclusion without recording private/disabled workloads or new state."""
    if state_dir.exists() or state_dir.is_symlink():
        if enrolled_generation(state_dir, worktree, False) is not None:
            raise AdmissionClosed("excluded-workload-on-enrolled-generation")
        return
    if _has_generation_marker(worktree):
        raise AdmissionClosed("excluded-workload-on-marked-generation")
