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


def _reflog_is_read_only(args: list[str]) -> bool:
    """Allow `git reflog [show|list|exists]`; expire, delete and unknown words write.

    A bare `git reflog <ref>` or `git reflog <log-option>` is Git's implicit show.
    """
    # Leading options may precede a subcommand, so a mutating word anywhere fails closed.
    if any(arg in {"expire", "delete", "drop", "write"} for arg in args):
        return False
    if not args or args[0] in {"show", "list", "exists"}:
        return True
    first = args[0]
    return first.startswith("-") or first == "HEAD" or first.startswith("refs/") or "@{" in first


REF_QUERY_CHECKS: dict[str, Callable[[list[str]], bool]] = {
    "reflog": _reflog_is_read_only,
    "remote": _remote_is_read_only,
    "symbolic-ref": _symbolic_ref_is_read_only,
    "worktree": _worktree_is_allowed,
    "tag": _tag_is_read_only,
}
