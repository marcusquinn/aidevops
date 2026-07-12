#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Static destructive-command matchers for command-policy-helper.py."""

from __future__ import annotations

import os
from pathlib import Path


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


def _rm_operands(args: list[str]) -> list[str]:
    operands: list[str] = []
    after_options = False
    for arg in args:
        if arg == "--":
            after_options = True
            continue
        if after_options or not arg.startswith("-"):
            operands.append(arg)
    return operands


def _canonical_operand(path: str, cwd: str) -> str | None:
    if not path or "\x00" in path or any(part == ".." for part in Path(path).parts):
        return None
    if path.startswith(("$", "~")):
        return None
    candidate = path if os.path.isabs(path) else os.path.join(cwd, path)
    return os.path.realpath(os.path.normpath(candidate))


def _is_temp_operand(path: str, cwd: str) -> bool:
    canonical = _canonical_operand(path, cwd)
    if not canonical:
        return False
    # nosec B108 -- these canonical roots classify operands; no temp file is created.
    roots = ["/tmp", "/var/tmp"]
    tmpdir = os.environ.get("TMPDIR", "")
    if tmpdir:
        roots.append(tmpdir)
    for root in roots:
        canonical_root = os.path.realpath(os.path.normpath(root))
        try:
            if (
                os.path.commonpath([canonical, canonical_root]) == canonical_root
                and canonical != canonical_root
            ):
                return True
        except ValueError:
            continue
    return False


def _is_root_or_home_operand(path: str, cwd: str) -> bool:
    canonical = _canonical_operand(path, cwd)
    if not canonical:
        return path in {"/", "~", "$HOME", "${HOME}"}
    home = os.path.realpath(str(Path.home()))
    return canonical == "/" or canonical == home or canonical.startswith(home + os.sep)


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


def _matches(matcher: str, argv: list[str], cwd: str) -> bool:
    if matcher in {"rm_recursive_force_root", "rm_recursive_force"}:
        return _matches_rm(matcher, argv, cwd)
    subcommand, git_args = _git_parts(argv)
    if not subcommand:
        return False
    return _matches_git(matcher, subcommand, git_args)


def _matches_rm(matcher: str, argv: list[str], cwd: str) -> bool:
    executable = os.path.basename(argv[0]) if argv else ""
    args = argv[1:]
    if (
        executable != "rm"
        or not _has_flag(args, "r", "--recursive")
        or not _has_flag(args, "f", "--force")
    ):
        return False
    operands = _rm_operands(args)
    if not operands or all(_is_temp_operand(path, cwd) for path in operands):
        return False
    is_root = any(_is_root_or_home_operand(path, cwd) for path in operands)
    return is_root if matcher == "rm_recursive_force_root" else not is_root


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
