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
