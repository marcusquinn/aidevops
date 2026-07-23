#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Repository-target and subcommand policy for the canonical Git guard."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

from canonical_git_readonly import CANONICAL_CHECKS

BLOCK_EXIT = 42
READ_ONLY = {
    "status",
    "diff",
    "diff-files",
    "log",
    "show",
    "rev-parse",
    "show-ref",
    "for-each-ref",
    "cat-file",
    "check-ref-format",
    "ls-files",
    "ls-remote",
    "ls-tree",
    "rev-list",
    "merge-base",
    "describe",
    "grep",
    "blame",
    "shortlog",
    "whatchanged",
    "name-rev",
    "count-objects",
    "version",
    "help",
}
GLOBAL_VALUE_OPTIONS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}


def real_git(explicit: str = "") -> str:
    """Resolve the real Git executable without selecting the sibling shim."""
    if explicit:
        return explicit
    guard_dir = Path(__file__).resolve().parent
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(directory or ".") / "git"
        try:
            if (
                candidate.is_file()
                and os.access(candidate, os.X_OK)
                and candidate.resolve().parent != guard_dir
            ):
                return str(candidate.resolve())
        except OSError:
            continue
    return shutil.which("git") or "/usr/bin/git"


def _git_output(real_git_path: str, cwd: str, *args: str) -> str:
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


def _is_canonical(real_git_path: str, cwd: str, git_prefix: list[str]) -> bool:
    git_dir = _git_output(
        real_git_path,
        cwd,
        *git_prefix,
        "rev-parse",
        "--path-format=absolute",
        "--git-dir",
    )
    common_dir = _git_output(
        real_git_path,
        cwd,
        *git_prefix,
        "rev-parse",
        "--path-format=absolute",
        "--git-common-dir",
    )
    return bool(
        git_dir
        and common_dir
        and os.path.realpath(git_dir) == os.path.realpath(common_dir)
    )


def _split_invocation(
    argv: list[str], base_cwd: str
) -> tuple[list[str], str, str, list[str]]:
    prefix: list[str] = []
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--":
            index += 1
            break
        if arg in GLOBAL_VALUE_OPTIONS:
            if index + 1 >= len(argv):
                return prefix, base_cwd, "", []
            prefix.extend([arg, argv[index + 1]])
            index += 2
            continue
        if arg.startswith("-"):
            prefix.append(arg)
            index += 1
            continue
        return prefix, base_cwd, arg, argv[index + 1 :]
    return prefix, base_cwd, "", argv[index:]


def _is_allowed_canonical(subcommand: str, args: list[str]) -> bool:
    if subcommand in READ_ONLY:
        return True
    checker = CANONICAL_CHECKS.get(subcommand)
    return bool(checker and checker(args))


def _repository_values(prefix: list[str]) -> list[str]:
    values = [
        prefix[index + 1]
        for index, option in enumerate(prefix[:-1])
        if option in {"-C", "--git-dir", "--work-tree"}
    ]
    values.extend(
        value.split("=", 1)[1]
        for value in prefix
        if value.startswith(("--git-dir=", "--work-tree="))
    )
    return values


def classify_git_argv(
    argv: list[str], cwd: str, real_git_path: str, check_unresolved: bool = False
) -> tuple[bool, str]:
    """Classify one Git argv vector against canonical-worktree policy."""
    prefix, effective_cwd, subcommand, args = _split_invocation(argv, cwd)
    if not subcommand:
        return False, "unable to classify Git subcommand"
    repo_values = _repository_values(prefix)
    if check_unresolved and any(
        value.startswith("~") or re.search(r"[$`*?\[\]{}]", value)
        for value in repo_values
    ):
        return False, "unresolved shell syntax in Git repository target"
    try:
        is_canonical = _is_canonical(real_git_path, effective_cwd, prefix)
    except RuntimeError as error:
        result = False, str(error)
    else:
        if not is_canonical:
            result = True, "linked worktree or non-repository target"
        elif _is_allowed_canonical(subcommand, args):
            result = True, "read-only canonical operation or linked-worktree creation"
        else:
            result = False, f"canonical worktree mutation via 'git {subcommand}'"
    return result
