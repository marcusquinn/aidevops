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
import re
import stat
import sys
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


def _trusted_symlink_chain(path: str, hops: int = 0) -> bool:
    """Check each link's containing chain, including intermediate link targets."""
    if hops >= 40:
        return False
    parts = Path(path).parts
    for index in range(1, len(parts) + 1):
        prefix = Path(*parts[:index])
        try:
            status = prefix.lstat()
            if stat.S_ISLNK(status.st_mode):
                if status.st_uid != 0 or not _trusted_chain(str(prefix.parent)):
                    return False
                target = os.readlink(prefix)
                if not os.path.isabs(target):
                    target = os.path.join(str(prefix.parent), target)
                return _trusted_symlink_chain(os.path.join(target, *parts[index:]), hops + 1)
        except OSError:
            return False
    return _trusted_chain(path)


def trusted_executable(name: str, search_path: str | None = None) -> str | None:
    """Return the first root-controlled ``name`` on PATH, or None.

    Python's platform default search path (``os.defpath``) is appended so an
    emptied or hostile PATH cannot hide the system tool; trust is still decided
    by ownership, never by location.
    """
    if not re.fullmatch(r"[A-Za-z0-9_.+-]+", name) or name in {".", ".."}:
        return None
    if search_path is None:
        search_path = os.pathsep.join(filter(None, (os.environ.get("PATH"), os.defpath)))
    for directory in search_path.split(os.pathsep):
        if not os.path.isabs(directory):
            continue
        candidate = os.path.join(directory, name)
        if not (os.path.isfile(candidate) and os.access(candidate, os.X_OK)):
            continue
        real = os.path.realpath(candidate)
        real_directory = os.path.realpath(directory)
        # Sticky shared dirs (e.g. /nix/store) are only acceptable as
        # ancestors: a sticky PATH dir such as /tmp lets any user plant a
        # symlink to an unrelated root-owned binary.
        if not (_root_controlled(os.path.dirname(real), directory=False)
                and _root_controlled(real_directory, directory=False)):
            continue
        if (_trusted_symlink_chain(candidate) and _trusted_chain(real)
                and _trusted_chain(real_directory)):
            return candidate
    return None


def require_trusted_executable(name: str) -> str:
    """Return a trusted ``name`` or raise FileNotFoundError (fail closed)."""
    resolved = trusted_executable(name)
    if resolved is None:
        raise FileNotFoundError(f"no root-controlled {name} found on PATH")
    return resolved


def main() -> int:
    """CLI: 1 unavailable, 2 invalid arguments, 3 untrusted interpreter."""
    if (len(sys.argv) not in {2, 3}
            or not re.fullmatch(r"[A-Za-z0-9_.+-]+", sys.argv[1])
            or sys.argv[1] in {".", ".."}):
        return 2
    interpreter = os.path.realpath(sys.executable)
    if (not _trusted_symlink_chain(sys.executable)
            or not _root_controlled(os.path.dirname(interpreter), directory=False)):
        return 3
    resolved = trusted_executable(sys.argv[1], sys.argv[2] if len(sys.argv) == 3 else None)
    if resolved is None:
        return 1
    print(resolved)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
