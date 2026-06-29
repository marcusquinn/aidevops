#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Git helpers for repo_metrics.py."""

from __future__ import annotations

import re
import subprocess
from pathlib import Path


def run_command(args: list[str], cwd: Path) -> subprocess.CompletedProcess[str] | None:
    try:
        return subprocess.run(
            args,
            cwd=str(cwd),
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return None


def repo_root(path: Path) -> Path:
    proc = run_command(["git", "rev-parse", "--show-toplevel"], path)
    if proc and proc.returncode == 0 and proc.stdout.strip():
        return Path(proc.stdout.strip()).resolve()
    return path.resolve()


def git_remote_slug(root: Path) -> str:
    proc = run_command(["git", "config", "--get", "remote.origin.url"], root)
    if not proc or proc.returncode != 0:
        return ""
    url = proc.stdout.strip()
    if not url:
        return ""
    match = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$", url)
    return match.group(1) if match else ""
