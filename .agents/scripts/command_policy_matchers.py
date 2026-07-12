#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Static destructive-command matchers for command-policy-helper.py."""

from __future__ import annotations

import os
from pathlib import Path

from command_policy_git_matchers import (
    _git_parts,
    _has_flag,
    _matches_git,
    _short_flags,
)

__all__ = [
    "_canonical_operand",
    "_git_parts",
    "_has_flag",
    "_is_root_or_home_operand",
    "_is_temp_operand",
    "_matches",
    "_matches_git",
    "_matches_rm",
    "_rm_operands",
    "_short_flags",
]


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
    roots = ["/tmp", "/var/tmp"]  # nosec B108 -- classification roots only; no temporary file is created.
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
    if not _is_recursive_force_rm(executable, args):
        return False
    operands = _rm_operands(args)
    if not operands or all(_is_temp_operand(path, cwd) for path in operands):
        return False
    is_root = any(_is_root_or_home_operand(path, cwd) for path in operands)
    return is_root if matcher == "rm_recursive_force_root" else not is_root


def _is_recursive_force_rm(executable: str, args: list[str]) -> bool:
    return (
        executable == "rm"
        and _has_flag(args, "r", "--recursive")
        and _has_flag(args, "f", "--force")
    )
