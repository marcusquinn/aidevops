# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Git-workspace scoping helpers for Tabby profile sync."""

from __future__ import annotations

import os

from canonical_write_policy_paths import (
    canonical_git_workspace_root,
    git_workspace_root_from_environment,
    is_within_workspace,
)


def normalize_cwd(path: str) -> str:
    """Normalize a profile cwd for conservative equality checks."""
    return os.path.normcase(os.path.realpath(os.path.expanduser(path)))


def workspace_root() -> str:
    """Resolve the same trusted root used by the canonical write policy."""
    return canonical_git_workspace_root(git_workspace_root_from_environment())


def eligible_path(path: str, root: str) -> bool:
    """Require a resolved path strictly beneath the trusted root."""
    resolved = normalize_cwd(path)
    return bool(root) and resolved != normalize_cwd(root) and is_within_workspace(resolved, root)


def is_buzz_path(path: str) -> bool:
    """Return True when path resolves to the legacy Buzz workspace."""
    return normalize_cwd(path) == normalize_cwd("~/.buzz")


def is_preserved_outside(path: str, root: str) -> bool:
    """Outside the workspace and not Buzz: treated as user-owned."""
    return not eligible_path(path, root) and not is_buzz_path(path)


def inside_root_category(
    cwd: str, normalized: str, registered_paths: set[str], seen_cwds: set[str]
) -> str | None:
    """Classify a managed profile whose cwd is inside the Git workspace."""
    cwd_is_known = os.path.isdir(os.path.expanduser(cwd)) or normalized in registered_paths
    category = None
    if not cwd_is_known:
        category = "stale"
    elif normalized in seen_cwds:
        category = "duplicate"
    else:
        seen_cwds.add(normalized)
    return category


def outside_summary(
    registered_paths: set[str], profile_cwds: list[object]
) -> tuple[int, tuple[str, ...]]:
    """Count registered repos outside the root and list outside profile cwds."""
    root = workspace_root()
    outside_count = sum(not eligible_path(path, root) for path in registered_paths)
    outside_cwds = tuple(
        cwd for cwd in profile_cwds if isinstance(cwd, str) and not eligible_path(cwd, root)
    )
    return outside_count, outside_cwds


def report_outside_workspace_repos(paths: set[str]) -> None:
    """Report registered repos skipped because they are outside the Git workspace."""
    root = workspace_root()
    for path in sorted(paths):
        if not eligible_path(path, root):
            print(f"Skipped {path}: outside Git workspace (no profile created)")
