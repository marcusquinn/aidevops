#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Argument-aware read-only checks for canonical Git operations."""

from __future__ import annotations

from typing import Callable

from canonical_git_config import config_is_read_only
from canonical_git_ref_queries import REF_QUERY_CHECKS


def _branch_is_read_only(args: list[str]) -> bool:
    if not args:
        return True
    mutating = {
        "-d",
        "-D",
        "-m",
        "-M",
        "-c",
        "-C",
        "-f",
        "--delete",
        "--move",
        "--copy",
        "--force",
        "--edit-description",
        "--set-upstream-to",
        "--unset-upstream",
    }
    if any(
        arg in mutating or arg.startswith(("--move=", "--copy=", "--set-upstream-to="))
        for arg in args
    ):
        return False
    listing = any(
        arg in {"--list", "--contains", "--merged", "--no-merged", "--points-at"}
        or arg.startswith(("--contains=", "--merged=", "--no-merged=", "--points-at="))
        for arg in args
    )
    return listing or all(arg.startswith("-") or arg in {"HEAD", "@"} for arg in args)


def _clean_is_read_only(args: list[str]) -> bool:
    return any(
        arg == "--dry-run"
        or (arg.startswith("-") and not arg.startswith("--") and "n" in arg[1:])
        for arg in args
    )


def _bundle_is_read_only(args: list[str]) -> bool:
    if not args or args[0] != "verify":
        return False
    bundle_args = args[1:]
    if not bundle_args:
        return False
    allowed_flags = {"-q", "--quiet"}
    paths = [arg for arg in bundle_args if arg not in allowed_flags]
    return len(paths) == 1 and not paths[0].startswith("-")


def _is_hash_object_write_flag(arg: str) -> bool:
    return arg == "-w" or (
        arg.startswith("-") and not arg.startswith("--") and "w" in arg[1:]
    )


def _hash_object_options(args: list[str]) -> list[str]:
    try:
        return args[: args.index("--")]
    except ValueError:
        return args


def _is_unknown_hash_object_option(arg: str) -> bool:
    read_only_options = {
        "--literally",
        "--no-filters",
        "--stdin",
        "--stdin-paths",
    }
    return (
        arg.startswith("-")
        and arg not in read_only_options
        and not arg.startswith("--path=")
    )


def _hash_object_is_read_only(args: list[str]) -> bool:
    """Allow hashing inputs while rejecting object database writes."""
    expect_value = False

    for arg in _hash_object_options(args):
        if expect_value:
            expect_value = False
            continue
        if arg == "-t":
            expect_value = True
            continue
        if _is_hash_object_write_flag(arg) or _is_unknown_hash_object_option(arg):
            return False

    return not expect_value


_ARCHIVE_FLAGS = frozenset({"--worktree-attributes", "--verbose", "-v", "--list", "-l"})
_ARCHIVE_VALUE_OPTIONS = frozenset({"--format", "--prefix"})
_STASH_QUERY_FLAGS = frozenset(
    {"-p", "--patch", "--stat", "--numstat", "--shortstat", "--name-only",
     "--name-status", "--oneline", "--no-color", "-u", "--include-untracked",
     "--only-untracked"}
)


def _archive_is_read_only(args: list[str]) -> bool:
    """Fail-closed allowlist: stdout archives only; unknown options may write."""
    skip_value = False
    for arg in args:
        if skip_value:
            skip_value = False
        elif arg == "--":
            break
        elif arg in _ARCHIVE_VALUE_OPTIONS:
            skip_value = True
        elif arg.startswith("-") and not (
            arg in _ARCHIVE_FLAGS
            or arg.partition("=")[0] in _ARCHIVE_VALUE_OPTIONS
            or (len(arg) == 2 and arg[1].isdigit())
        ):
            return False
    return not skip_value


def _stash_is_read_only(args: list[str]) -> bool:
    """Allow `git stash list|show` with allowlisted display flags only."""
    return bool(args) and args[0] in {"list", "show"} and all(
        not arg.startswith("-") or arg in _STASH_QUERY_FLAGS for arg in args[1:]
    )


CANONICAL_CHECKS: dict[str, Callable[[list[str]], bool]] = {
    "archive": _archive_is_read_only,
    "stash": _stash_is_read_only,
    "branch": _branch_is_read_only,
    "bundle": _bundle_is_read_only,
    "config": config_is_read_only,
    "clean": _clean_is_read_only,
    "hash-object": _hash_object_is_read_only,
    **REF_QUERY_CHECKS,
}
