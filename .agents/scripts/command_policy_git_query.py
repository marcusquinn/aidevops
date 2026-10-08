#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded read-only git queries for command-policy network analysis."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

_GIT_QUERY_TIMEOUT_ENV = "AIDEVOPS_GIT_POLICY_QUERY_TIMEOUT_SECONDS"
_GIT_QUERY_DEFAULT_TIMEOUT = 10
_GIT_QUERY_ATTEMPTS = 2


def _git_query_timeout() -> int:
    """Per-attempt budget; host load made the former fixed 5 s deny (GH#34040)."""
    raw = os.environ.get(_GIT_QUERY_TIMEOUT_ENV, "").strip()
    if raw.isdigit() and 1 <= int(raw) <= 60:
        return int(raw)
    return _GIT_QUERY_DEFAULT_TIMEOUT


def _run_git_query_detailed(
    cwd: str, args: list[str], ok_codes: tuple[int, ...] = (0,)
) -> tuple[list[str] | None, str]:
    """Run a read-only git query with one retry.

    Returns (stdout lines, "") on success, or (None, failure) where failure is
    a fixed token (timeout, spawn-error, exit-N) safe to show in a denial.
    """
    git_binary = "/usr/bin/git" if Path("/usr/bin/git").is_file() else "git"
    failure = "not-run"
    for _attempt in range(_GIT_QUERY_ATTEMPTS):
        try:
            resolved = subprocess.run(  # nosec B603 -- argv is fixed except validated cwd/remote data; shell execution is disabled.
                [git_binary, "-C", cwd, *args],
                capture_output=True,
                text=True,
                timeout=_git_query_timeout(),
                check=False,
            )
        except subprocess.TimeoutExpired:
            failure = "timeout"
            continue
        except (OSError, subprocess.SubprocessError):
            failure = "spawn-error"
            continue
        if resolved.returncode in ok_codes:
            return [line for line in resolved.stdout.splitlines() if line], ""
        failure = f"exit-{resolved.returncode}"
    return None, failure
