#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared-metadata policy and removal checks for Git worktrees."""

from __future__ import annotations

import os
from pathlib import Path

from canonical_git_invocation import GLOBAL_VALUE_OPTIONS
from canonical_git_management import is_registered_common_dir
from canonical_git_repository import git_output as _git_output


def _worktree_cwd(cwd: str, prefix: list[str]) -> Path:
    """Apply Git's successive -C options without interpreting other option values."""
    directory = Path(cwd)
    remaining = iter(prefix)
    for option in remaining:
        if option in GLOBAL_VALUE_OPTIONS:
            value = next(remaining, "")
            if option == "-C" and value:
                directory = (directory / value).resolve()
        elif option.startswith("-C") and option[2:]:
            directory = (directory / option[2:]).resolve()
    return directory


def _worktree_remove_target(args: list[str]) -> str:
    """Return the single remove target when args are in the safe subset."""
    target = ""
    invalid = not args or args[0] != "remove"
    option_terminator = False
    for arg in ([] if invalid else args[1:]):
        if option_terminator:
            if target:
                invalid = True
            else:
                target = arg
        elif arg == "--":
            option_terminator = True
        elif arg in {"-f", "--force"}:
            continue
        elif arg.startswith("-"):
            invalid = True
        elif target:
            invalid = True
        else:
            target = arg
    return "" if invalid else target


def git_repo_identity(
    real_git_path: str, cwd: str, prefix: list[str]
) -> tuple[str, str, str]:
    """Return common dir, git dir, and top-level for a Git target."""
    common_dir = _git_output(
        real_git_path,
        cwd,
        *prefix,
        "rev-parse",
        "--path-format=absolute",
        "--git-common-dir",
    )
    git_dir = _git_output(
        real_git_path,
        cwd,
        *prefix,
        "rev-parse",
        "--path-format=absolute",
        "--git-dir",
    )
    top = _git_output(
        real_git_path,
        cwd,
        *prefix,
        "rev-parse",
        "--path-format=absolute",
        "--show-toplevel",
    )
    return common_dir, git_dir, top


def is_linked_worktree_remove_for_canonical(
    real_git_path: str,
    effective_cwd: str,
    prefix: list[str],
    args: list[str],
) -> bool:
    """Allow removing only linked worktrees that belong to this canonical repo."""
    target = _worktree_remove_target(args)
    allowed = False

    if target:
        canonical_common_dir, _canonical_git_dir, canonical_top = git_repo_identity(
            real_git_path, effective_cwd, prefix
        )
        target_path = Path(target).expanduser()
        if not target_path.is_absolute():
            target_path = _worktree_cwd(effective_cwd, prefix) / target_path
        target_real = os.path.realpath(target_path)
        target_common_dir, target_git_dir, target_top = git_repo_identity(
            real_git_path, target_real, []
        )
        required_paths = [
            canonical_common_dir,
            canonical_top,
            target_common_dir,
            target_git_dir,
            target_top,
        ]
        same_common_dir = os.path.realpath(target_common_dir) == os.path.realpath(
            canonical_common_dir
        )
        separate_git_dir = os.path.realpath(target_git_dir) != os.path.realpath(
            target_common_dir
        )
        target_is_toplevel = os.path.realpath(target_top) == target_real
        target_is_not_canonical = target_real != os.path.realpath(canonical_top)
        allowed = all(
            [
                all(required_paths),
                same_common_dir,
                separate_git_dir,
                target_is_toplevel,
                target_is_not_canonical,
            ]
        )
    return allowed


def classify_linked_operation(
    real_git_path: str, cwd: str, prefix: list[str], command: tuple[str, list[str]],
) -> tuple[bool, str]:
    """Classify a non-canonical target; shared worktree metadata stays audited."""
    subcommand, args = command
    result = True, "linked worktree or non-repository target"
    if subcommand == "worktree" and not (args and args[0] in {"list", "add"}):
        common_dir = _git_output(
            real_git_path, cwd, *prefix,
            "rev-parse", "--path-format=absolute", "--git-common-dir",
        )
        if common_dir and is_registered_common_dir(common_dir):
            if is_linked_worktree_remove_for_canonical(
                real_git_path, cwd, prefix, args
            ):
                result = True, "linked-worktree removal for canonical repository"
            else:
                result = False, (
                    f"shared worktree metadata mutation via 'git {subcommand}' "
                    "from a linked worktree"
                )
    return result
