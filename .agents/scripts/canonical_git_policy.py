#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Repository-target and subcommand policy for the canonical Git guard."""

from __future__ import annotations

import os
import re
import shlex
import tempfile
from pathlib import Path

from trusted_executable import trusted_executable

from canonical_git_invocation import (
    clone_paths,
    is_version_query,
    repository_values,
    split_invocation,
)
from canonical_git_management import is_managed_root, is_registered_common_dir
from canonical_git_readonly import CANONICAL_CHECKS
from canonical_git_repository import git_output as _git_output
from canonical_git_repository import is_canonical as _is_canonical
from canonical_git_repository import real_git

BLOCK_EXIT = 42
READ_ONLY = frozenset(
    (
        "status",
        "diff",
        "diff-files",
        "diff-tree",
        "log",
        "show",
        "rev-parse",
        "show-ref",
        "for-each-ref",
        "cat-file",
        "check-attr",
        "check-ignore",
        "check-mailmap",
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
    )
)


def _is_allowed_canonical(subcommand: str, args: list[str]) -> bool:
    if subcommand in READ_ONLY:
        return True
    checker = CANONICAL_CHECKS.get(subcommand)
    return bool(checker and checker(args))


def _is_isolated_prospective_merge_tree(
    real_git_path: str,
    effective_cwd: str,
    prefix: list[str],
    subcommand: str,
    args: list[str],
) -> bool:
    """Allow the full-loop read probe only in its private temporary bare repo."""
    if (
        subcommand != "merge-tree"
        or len(args) != 3
        or args[0] != "--write-tree"
        or not all(re.fullmatch(r"[0-9a-fA-F]{40,64}", value) for value in args[1:])
    ):
        return False
    if (
        _git_output(
            real_git_path,
            effective_cwd,
            *prefix,
            "rev-parse",
            "--is-bare-repository",
        )
        != "true"
    ):
        return False
    git_dir = _git_output(
        real_git_path,
        effective_cwd,
        *prefix,
        "rev-parse",
        "--path-format=absolute",
        "--git-dir",
    )
    if not git_dir or os.path.basename(git_dir) != "repository.git":
        return False
    context_dir = os.path.dirname(os.path.realpath(git_dir))
    if not os.path.basename(context_dir).startswith("aidevops-prospective-todo."):
        return False
    return os.path.dirname(context_dir) == os.path.realpath(tempfile.gettempdir())


def _is_isolated_routines_publisher(
    real_git_path: str,
    effective_cwd: str,
    prefix: list[str],
    subcommand: str,
) -> bool:
    """Allow bounded mutations only in the routines publisher's private clone."""
    if subcommand not in {"add", "commit", "fetch", "push"}:
        return False
    git_dir = _git_output(
        real_git_path,
        effective_cwd,
        *prefix,
        "rev-parse",
        "--path-format=absolute",
        "--git-dir",
    )
    repo_dir = _git_output(
        real_git_path,
        effective_cwd,
        *prefix,
        "rev-parse",
        "--path-format=absolute",
        "--show-toplevel",
    )
    if not git_dir or not repo_dir:
        return False
    repo_dir = os.path.realpath(repo_dir)
    context_dir = os.path.dirname(repo_dir)
    return bool(
        os.path.basename(repo_dir) == "repo"
        and re.fullmatch(r"routines-publisher\.[A-Za-z0-9]+", os.path.basename(context_dir))
        and os.path.dirname(context_dir) == os.path.realpath(tempfile.gettempdir())
        and os.path.realpath(git_dir) == os.path.join(repo_dir, ".git")
    )


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


def _git_repo_identity(
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


def _is_linked_worktree_remove_for_canonical(
    real_git_path: str,
    effective_cwd: str,
    prefix: list[str],
    args: list[str],
) -> bool:
    """Allow removing only linked worktrees that belong to this canonical repo."""
    target = _worktree_remove_target(args)
    allowed = False

    if target:
        canonical_common_dir, _canonical_git_dir, canonical_top = _git_repo_identity(
            real_git_path, effective_cwd, prefix
        )
        target_path = Path(target).expanduser()
        if not target_path.is_absolute():
            target_path = Path(effective_cwd) / target_path
        target_real = os.path.realpath(target_path)
        target_common_dir, target_git_dir, target_top = _git_repo_identity(
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


def _gh_credential_executable(helper: str) -> str:
    """Extract only the absolute executable from an exact gh auth helper."""
    if not helper.startswith("!"):
        return ""
    try:
        command = shlex.split(helper[1:])
    except ValueError:
        return ""
    if len(command) != 3 or command[1:] != ["auth", "git-credential"]:
        return ""
    executable = command[0]
    name = os.path.basename(executable)
    if name not in {"gh", ".gh-wrapped"} or not os.path.isabs(executable):
        return ""
    return executable


def _is_clone_credential_config(value: str) -> bool:
    """Accept GitHub CLI credential resets/helpers, never arbitrary shell helpers."""
    key, separator, helper = value.partition("=")
    if not separator or not re.fullmatch(r"credential(?:\.https://[^\s/]+)?\.helper", key):
        return False
    if not helper:
        return True
    executable = _gh_credential_executable(helper)
    if not executable:
        return False
    name = os.path.basename(executable)
    trusted = trusted_executable(name, os.path.dirname(executable))
    return bool(trusted and os.path.realpath(executable) == os.path.realpath(trusted))


def _clone_cwd(cwd: str, prefix: list[str]) -> Path | None:
    """Resolve -C pairs and permit only GitHub CLI's trusted credential config."""
    clone_cwd = Path(cwd)
    index = 0
    while index < len(prefix):
        option = prefix[index]
        if option not in {"-C", "-c"} or index + 1 >= len(prefix):
            return None
        value = prefix[index + 1]
        if option == "-c":
            if not _is_clone_credential_config(value):
                return None
        elif value:
            clone_cwd = (clone_cwd / value).resolve()
        index += 2
    return clone_cwd


def _clone_path_is_protected(path: Path, canonical_top: str) -> bool:
    """Check checkout ancestry and registered separate Git metadata ancestry."""
    if canonical_top and path.is_relative_to(Path(canonical_top).resolve()):
        return True
    return any(
        is_managed_root(str(parent)) or is_registered_common_dir(str(parent))
        for parent in (path, *path.parents)
    )


def _clone_path_is_allowed(
    value: str, clone_cwd: Path, canonical_top: str, check_unresolved: bool,
) -> bool:
    """Resolve one literal path and require an unprotected absent/empty target."""
    if check_unresolved and (
        value.startswith("~") or re.search(r"[$`*?\[\]{}]", value)
    ):
        return False
    path = (clone_cwd / value).resolve()
    if _clone_path_is_protected(path, canonical_top):
        return False
    return not path.exists() or (
        path.is_dir() and next(path.iterdir(), None) is None
    )


def _is_clone_outside_canonical(
    real_git_path: str,
    cwd: str,
    prefix: list[str],
    args: list[str],
    check_unresolved: bool,
) -> bool:
    """Allow only explicit, empty clone targets outside canonical roots."""
    destination, auxiliary = clone_paths(args)
    if not destination or any(
        os.environ.get(name)
        for name in (
            "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
            "GIT_OBJECT_DIRECTORY", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
            "GIT_TEMPLATE_DIR", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM",
        )
    ):
        return False
    canonical_top = _git_output(
        real_git_path, cwd, *prefix, "rev-parse", "--show-toplevel",
    )
    try:
        # Git applies successive -C options relative to the previous cwd.
        clone_cwd = _clone_cwd(cwd, prefix)
        if clone_cwd is None:
            return False
        for value in [destination, *auxiliary]:
            if not _clone_path_is_allowed(
                value, clone_cwd, canonical_top, check_unresolved
            ):
                return False
        return True
    except (OSError, RuntimeError, ValueError):
        return False


def _classify_canonical_operation(
    real_git_path: str, cwd: str, prefix: list[str], subcommand: str,
    args: list[str], check_unresolved: bool,
) -> tuple[bool, str]:
    """Classify narrow exceptions after the repository identity is established."""
    if _is_isolated_prospective_merge_tree(
        real_git_path, cwd, prefix, subcommand, args
    ):
        return True, "isolated prospective merge-tree probe"
    if _is_isolated_routines_publisher(real_git_path, cwd, prefix, subcommand):
        return True, "isolated routines publisher mutation"
    if subcommand == "worktree" and _is_linked_worktree_remove_for_canonical(
        real_git_path, cwd, prefix, args
    ):
        return True, "linked-worktree removal for canonical repository"
    if subcommand == "clone":
        if _is_clone_outside_canonical(
            real_git_path, cwd, prefix, args, check_unresolved
        ):
            return True, "clone to an explicit destination outside canonical checkouts"
        return False, (
            "clone requires an explicit absent or empty destination outside canonical "
            "checkouts and safe options; clone into a path outside this checkout "
            "(the workspace layout in reference/repo-organization.md), "
            "or run it from that path's parent"
        )
    if _is_allowed_canonical(subcommand, args):
        return True, "read-only canonical operation or linked-worktree creation"
    return False, f"canonical worktree mutation via 'git {subcommand}'"


def classify_git_argv(
    argv: list[str], cwd: str, real_git_path: str, check_unresolved: bool = False
) -> tuple[bool, str]:
    """Classify one Git argv vector against canonical-worktree policy."""
    prefix, effective_cwd, subcommand, args = split_invocation(argv, cwd)
    repo_values = repository_values(prefix)
    if check_unresolved and any(
        value.startswith("~") or re.search(r"[$`*?\[\]{}]", value)
        for value in repo_values
    ):
        return False, "unresolved shell syntax in Git repository target"
    if is_version_query(argv):
        return True, "read-only Git version query"
    if not subcommand:
        return False, "unable to classify Git subcommand"
    try:
        is_canonical = _is_canonical(real_git_path, effective_cwd, prefix)
    except RuntimeError as error:
        result = False, str(error)
    else:
        if not is_canonical:
            result = True, "linked worktree or non-repository target"
        else:
            result = _classify_canonical_operation(
                real_git_path, effective_cwd, prefix, subcommand, args, check_unresolved
            )
    return result
