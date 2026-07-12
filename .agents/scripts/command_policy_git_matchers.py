#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Static Git command matchers for the command policy."""

from __future__ import annotations

import os


def _short_flags(args: list[str]) -> set[str]:
    flags: set[str] = set()
    for arg in args:
        if arg == "--":
            break
        if arg.startswith("-") and not arg.startswith("--"):
            flags.update(arg[1:])
    return flags


def _has_flag(args: list[str], short: str, long: str) -> bool:
    option_args = args[: args.index("--")] if "--" in args else args
    return long in option_args or short in _short_flags(option_args)


def _git_parts(argv: list[str]) -> tuple[str, list[str]]:
    if not argv or os.path.basename(argv[0]) != "git":
        return "", []
    index = 1
    value_options = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}
    while index < len(argv):
        arg = argv[index]
        if arg in value_options:
            index += 2
            continue
        if arg.startswith("-"):
            index += 1
            continue
        return arg, argv[index + 1 :]
    return "", []


def _matches_git(matcher: str, subcommand: str, git_args: list[str]) -> bool:
    short_flags = _short_flags(git_args)
    staged = "--staged" in git_args or "S" in short_flags
    worktree = "--worktree" in git_args or "W" in short_flags
    matches = _git_worktree_matches(subcommand, git_args, staged, worktree)
    matches.update(_git_history_matches(subcommand, git_args, short_flags))
    return matches.get(matcher, False)


def _git_worktree_matches(
    subcommand: str,
    git_args: list[str],
    staged: bool,
    worktree: bool,
) -> dict[str, bool]:
    return {
        "git_checkout_worktree_path": subcommand == "checkout" and "--" in git_args,
        "git_restore_worktree": subcommand == "restore" and (worktree or not staged),
        "git_reset_destructive": subcommand == "reset"
        and any(arg in {"--hard", "--merge"} for arg in git_args),
    }


def _git_history_matches(
    subcommand: str, git_args: list[str], short_flags: set[str]
) -> dict[str, bool]:
    return {
        "git_clean_force": subcommand == "clean"
        and _has_flag(git_args, "f", "--force")
        and not _has_flag(git_args, "n", "--dry-run"),
        "git_push_force": subcommand == "push"
        and ("--force" in git_args or "f" in short_flags),
        "git_branch_force_delete": subcommand == "branch" and "D" in short_flags,
        "git_stash_delete": subcommand == "stash"
        and bool(git_args)
        and git_args[0] in {"drop", "clear"},
    }
