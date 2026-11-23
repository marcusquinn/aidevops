#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Resolve the configured linked-worktree base for the canonical write policy."""

from __future__ import annotations

import json
import os
from pathlib import Path


WORKTREE_BASE_DIR_ENVS = ("AIDEVOPS_WORKTREE_BASE_DIR", "AIDEVOPS_WORKTREES_DIR")
REPOS_JSON_ENV = "AIDEVOPS_REPOS_JSON"
REPOS_JSON_KEYS = ("worktree_base_dir", "worktrees_dir")


def _configured_base(repos_json: str) -> str:
    try:
        config = json.loads(Path(repos_json).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    if not isinstance(config, dict):
        return ""
    for key in REPOS_JSON_KEYS:
        value = config.get(key)
        if isinstance(value, str) and value and value != "null":
            return value
    return ""


def worktree_base_dir_from_environment() -> str:
    """Return the configured linked-worktree base, as worktree-paths.sh does.

    GH#39739: worktree-helper.sh places worktrees here, so a linked worktree
    beneath it is trusted even when the base is outside the Git workspace.
    """
    for name in WORKTREE_BASE_DIR_ENVS:
        if os.environ.get(name):
            return os.environ[name]
    repos_json = os.environ.get(REPOS_JSON_ENV) or str(
        Path.home() / ".config" / "aidevops" / "repos.json"
    )
    return _configured_base(repos_json) or str(Path.home() / "Git" / "_worktrees")
