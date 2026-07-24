#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Read-only checks for Git ref and worktree query subcommands."""

from __future__ import annotations

from typing import Callable


def _remote_is_read_only(args: list[str]) -> bool:
    return not args or args[0] in {"-v", "--verbose", "get-url", "show"}


def _worktree_is_allowed(args: list[str]) -> bool:
    return bool(args) and args[0] in {"list", "add"}


def _tag_is_read_only(args: list[str]) -> bool:
    return not args or any(
        arg in {"-l", "--list", "--contains", "--points-at"}
        or arg.startswith(("--contains=", "--points-at="))
        for arg in args
    )


def _symbolic_ref_is_read_only(args: list[str]) -> bool:
    read_flags = {"-q", "--quiet", "--short", "--recurse", "--no-recurse"}
    return (
        sum(arg not in read_flags for arg in args) == 1
        and all(arg in read_flags or not arg.startswith("-") for arg in args)
    )


REF_QUERY_CHECKS: dict[str, Callable[[list[str]], bool]] = {
    "remote": _remote_is_read_only,
    "symbolic-ref": _symbolic_ref_is_read_only,
    "worktree": _worktree_is_allowed,
    "tag": _tag_is_read_only,
}
