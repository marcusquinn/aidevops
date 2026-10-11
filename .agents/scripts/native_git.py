# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Native Git discovery shared by policy adapters; never recurse into a shim."""
from __future__ import annotations

import os
from pathlib import Path


class NativeGitUnavailable(RuntimeError):
    """No usable native Git exists, or an explicit override is invalid."""


def is_git_shim(candidate: str) -> bool:
    """Identify every shim generation by its resolved sibling policy guard."""
    try:
        directory = Path(candidate).resolve(strict=True).parent
    except (OSError, RuntimeError):
        return True  # Broken or cyclic links cannot be native Git.
    return (directory / "canonical-git-command-guard.py").is_file()


def _usable(candidate: str) -> bool:
    return (os.path.isabs(candidate) and os.path.isfile(candidate)
            and os.access(candidate, os.X_OK) and not is_git_shim(candidate))


def real_git(explicit: str = "") -> str:
    """Use a validated override or the first non-shim absolute PATH candidate."""
    override = (explicit or os.environ.get("AIDEVOPS_REAL_GIT_BIN", "")
                or os.environ.get("AIDEVOPS_REAL_GIT", ""))
    if override:
        if not _usable(override):
            raise NativeGitUnavailable("BLOCKED: invalid native Git override")
        return os.path.realpath(override)
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        if not os.path.isabs(directory):
            continue
        candidate = os.path.join(directory, "git")
        if _usable(candidate):
            return os.path.realpath(candidate)
    raise NativeGitUnavailable("BLOCKED: native Git unavailable on PATH")
