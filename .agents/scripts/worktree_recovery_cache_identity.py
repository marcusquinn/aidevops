#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Identity proofs for approved cache roots and framework-owned state paths."""

from pathlib import Path
import re
import stat
from typing import Optional, Tuple

from worktree_recovery_cache_policy_common import (
    EGG_INFO_MARKER,
    EGG_INFO_SUFFIX,
    MARKED_COMPONENTS,
    ordinary_directory,
    relative_parts,
)

# aidevops-owned ephemeral state at exact repository-relative locations. These
# paths are meaningless once the source worktree is gone, so they never make an
# archive dirty; they are not pruned separately because they are tiny.
FRAMEWORK_STATE_DIRECTORIES = {(".agents", "loop-state"), (".agents", "tmp")}
FRAMEWORK_STATE_FILES = {(".agents", ".full-loop-cleanup-deferred")}
FRAMEWORK_STATE_FILE_PATTERN = re.compile(r"^todo/batches/[^/]+\.json\.lock$")


def root_marker(root_parts: Tuple[str, ...]) -> Optional[str]:
    """Return the identity file a generic-named approved root must contain."""
    name = root_parts[-1]
    if name in MARKED_COMPONENTS:
        return MARKED_COMPONENTS[name]
    if name.endswith(EGG_INFO_SUFFIX) and len(name) > len(EGG_INFO_SUFFIX):
        return EGG_INFO_MARKER
    return None


def ordinary_file(path: Path) -> bool:
    """Return whether a path is a regular file and not a symlink."""
    try:
        return stat.S_ISREG(path.lstat().st_mode)
    except OSError:
        return False


def approved_root_directory(
    root: Path, root_parts: Tuple[str, ...]
) -> Optional[Path]:
    """Resolve an approved root, requiring its identity file when named generically."""
    candidate = ordinary_directory(root, root_parts)
    marker = root_marker(root_parts)
    if candidate is None or marker is None:
        return candidate
    return candidate if ordinary_file(candidate / marker) else None


def framework_state_path(raw_path: str) -> bool:
    """Return whether a status path is exact aidevops-owned ephemeral state."""
    parts = relative_parts(raw_path)
    if parts is None:
        return False
    in_state_directory = any(
        parts[: len(directory)] == directory for directory in FRAMEWORK_STATE_DIRECTORIES
    )
    return any(
        (
            in_state_directory,
            parts in FRAMEWORK_STATE_FILES,
            FRAMEWORK_STATE_FILE_PATTERN.match("/".join(parts)) is not None,
        )
    )


def ordinary_state_entry(root: Path, raw_path: str) -> bool:
    """Prove framework state is a plain file or directory without symlinks."""
    parts = relative_parts(raw_path)
    if parts is None or ordinary_directory(root, parts[:-1]) is None:
        return False
    entry = root.joinpath(*parts)
    try:
        mode = entry.lstat().st_mode
    except OSError:
        return False
    return stat.S_ISREG(mode) or stat.S_ISDIR(mode)
