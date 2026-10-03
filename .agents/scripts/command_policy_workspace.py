#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Projects-workspace containment helpers for the command policy."""

from __future__ import annotations

import os
import shlex
from pathlib import Path
from typing import Any

WORKSPACE_ROOT_ENV = "AIDEVOPS_ACCOUNT_MUTATION_WORKSPACE_ROOT"


def account_mutation_workspace_root_from_environment() -> str:
    """Return the inherited workspace root, defaulting to the projects directory."""
    if WORKSPACE_ROOT_ENV in os.environ:
        return os.environ[WORKSPACE_ROOT_ENV]
    return str(Path.home() / "Git")


def _canonical_workspace_root(workspace_root: str) -> str:
    if not workspace_root:
        return ""
    root = os.path.realpath(os.path.expanduser(workspace_root))
    home = os.path.realpath(str(Path.home()))
    if root in {os.path.abspath(os.sep), home} or not os.path.isdir(root):
        return ""
    return root


def _is_within_workspace(cwd: str, workspace_root: str) -> bool:
    if not os.path.isdir(cwd):
        return False
    try:
        return os.path.commonpath([cwd, workspace_root]) == workspace_root
    except ValueError:
        return False


def _source_argv(source: dict[str, Any]) -> list[str] | None:
    value = source.get("value")
    if source.get("kind") == "argv":
        return value
    try:
        return shlex.split(value) if source.get("kind") == "command" else None
    except (TypeError, ValueError):
        return None


def _is_direct_invocation(argv: list[str], source: dict[str, Any] | None) -> bool:
    """Return whether the submitted command is the bare invocation itself."""
    return source is None or _source_argv(source) == argv
