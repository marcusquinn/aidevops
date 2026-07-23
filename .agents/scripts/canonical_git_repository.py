#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Native Git resolution and canonical-repository probes."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path


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


def git_output(real_git_path: str, cwd: str, *args: str) -> str:
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


def is_canonical(real_git_path: str, cwd: str, git_prefix: list[str]) -> bool:
    git_dir = git_output(
        real_git_path,
        cwd,
        *git_prefix,
        "rev-parse",
        "--path-format=absolute",
        "--git-dir",
    )
    common_dir = git_output(
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
