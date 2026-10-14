#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded clone destinations and credential options for the canonical Git guard."""

from __future__ import annotations

import os
import re
from pathlib import Path

from trusted_executable import trusted_executable

from canonical_git_invocation import clone_paths
from canonical_git_management import is_managed_root, is_registered_common_dir
from canonical_git_repository import git_output as _git_output


def _gh_credential_executable(helper: str) -> str:
    """Extract only the absolute executable from an exact gh auth helper."""
    match = re.fullmatch(
        r'!(?:"(?P<quoted>/[A-Za-z0-9_./+ -]+)"|(?P<plain>/[A-Za-z0-9_./+-]+))'
        r' auth git-credential',
        helper,
    )
    if not match:
        return ""
    executable = match.group("quoted") or match.group("plain")
    name = os.path.basename(executable)
    if name not in {"gh", ".gh-wrapped"}:
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


def is_clone_outside_canonical(
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
