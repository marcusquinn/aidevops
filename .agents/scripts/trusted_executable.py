# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Resolve trust-sensitive executables through PATH without trusting user files.

Policy and identity checks must not run a tool an agent placed earlier on
PATH. Accept the first PATH entry whose real executable, real parent chain and
PATH directory chain are root-controlled. No distro-specific roots: the same
rule covers macOS, FHS Linux and store-symlinked layouts.

The root source-access broker keeps its own copy in source_access_core.py
because it may only load its fixed, root-owned file set.
"""
from __future__ import annotations

import os
import stat
from pathlib import Path


def _root_controlled(path: str, *, directory: bool) -> bool:
    """True when only root can modify ``path`` (sticky dirs may be shared)."""
    try:
        status = os.stat(path)
    except OSError:
        return False
    if status.st_uid != 0:
        return False
    if not status.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        return True
    return directory and bool(status.st_mode & stat.S_ISVTX)


def _trusted_chain(path: str) -> bool:
    """True when ``path`` and every ancestor directory are root-controlled."""
    current = Path(path)
    if not _root_controlled(str(current), directory=current.is_dir()):
        return False
    return all(_root_controlled(str(parent), directory=True) for parent in current.parents)


def trusted_executable(name: str, search_path: str | None = None) -> str | None:
    """Return the first root-controlled ``name`` on PATH, or None.

    Python's platform default search path (``os.defpath``) is appended so an
    emptied or hostile PATH cannot hide the system tool; trust is still decided
    by ownership, never by location.
    """
    if search_path is None:
        search_path = os.pathsep.join(filter(None, (os.environ.get("PATH"), os.defpath)))
    for directory in search_path.split(os.pathsep):
        if not os.path.isabs(directory):
            continue
        candidate = os.path.join(directory, name)
        if not (os.path.isfile(candidate) and os.access(candidate, os.X_OK)):
            continue
        if _trusted_chain(os.path.realpath(candidate)) and _trusted_chain(os.path.realpath(directory)):
            return candidate
    return None


def require_trusted_executable(name: str) -> str:
    """Return a trusted ``name`` or raise FileNotFoundError (fail closed)."""
    resolved = trusted_executable(name)
    if resolved is None:
        raise FileNotFoundError(f"no root-controlled {name} found on PATH")
    return resolved
