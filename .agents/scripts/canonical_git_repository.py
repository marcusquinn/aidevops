#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Native Git resolution and canonical-repository probes."""

from __future__ import annotations

import os
import subprocess

from native_git import real_git

from canonical_git_management import (
    is_managed_root,
    is_registered_common_dir,
    linked_worktree_root,
)


def git_output(real_git_path: str, cwd: str, *args: str) -> str:
    try:
        result = subprocess.run(
            [real_git_path, *args],
            cwd=cwd,
            text=True,
            capture_output=True,
            timeout=5,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("native Git repository probe timed out") from error
    except OSError as error:
        raise RuntimeError("native Git repository probe failed to start") from error
    return result.stdout.strip() if result.returncode == 0 else ""


def _has_worktree_override(git_prefix: list[str]) -> bool:
    return bool(
        os.environ.get("GIT_WORK_TREE")
        or "--work-tree" in git_prefix
        or any(value.startswith("--work-tree=") for value in git_prefix)
    )


def is_canonical(real_git_path: str, cwd: str, git_prefix: list[str]) -> bool:
    git_dir = git_output(
        real_git_path,
        cwd,
        *git_prefix,
        "rev-parse",
        "--path-format=absolute",
        "--git-dir",
    )
    common_dir = git_output(
        real_git_path,
        cwd,
        *git_prefix,
        "rev-parse",
        "--path-format=absolute",
        "--git-common-dir",
    )
    repo_root = git_output(
        real_git_path,
        cwd,
        *git_prefix,
        "rev-parse",
        "--path-format=absolute",
        "--show-toplevel",
    )
    canonical_common_dir = os.path.realpath(common_dir) if common_dir else ""
    canonical_git_dir = os.path.realpath(git_dir) if git_dir else ""
    configured_worktree = git_output(
        real_git_path,
        cwd,
        *git_prefix,
        "config",
        "--path",
        "--get",
        "core.worktree",
    )
    if _has_worktree_override(git_prefix):
        pass
    elif configured_worktree:
        worktree_path = Path(configured_worktree).expanduser()
        if not worktree_path.is_absolute():
            worktree_path = Path(canonical_common_dir) / worktree_path
        repo_root = str(worktree_path.resolve())
    elif (
        canonical_git_dir == canonical_common_dir
        and os.path.basename(canonical_common_dir) == ".git"
    ):
        repo_root = os.path.dirname(canonical_common_dir)
    if not git_dir or not common_dir or not repo_root:
        return False
    if canonical_git_dir == canonical_common_dir:
        return is_managed_root(repo_root) or is_registered_common_dir(
            canonical_common_dir
        )
    linked_root = linked_worktree_root(canonical_git_dir)
    if linked_root and linked_root == Path(repo_root).resolve():
        return False
    return is_managed_root(repo_root)
