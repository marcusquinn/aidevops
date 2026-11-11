"""Default project for Buzz plugin agents that name no project folder."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import json
import os
from pathlib import Path

from _team_interface_buzz_runtime_io import RuntimeError


AIDEVOPS_UPSTREAM_SLUG = "marcusquinn/aidevops"


def _is_aidevops_entry(entry):
    """Whether one repos.json entry is an aidevops checkout (upstream or fork)."""
    if not isinstance(entry, dict):
        return False
    slug = entry.get("slug")
    if not isinstance(slug, str) or not isinstance(entry.get("path"), str):
        return False
    return slug == AIDEVOPS_UPSTREAM_SLUG or slug.endswith("/aidevops")


def aidevops_project_root(repos_path):
    """The registered aidevops checkout: the upstream slug first, then a fork."""
    try:
        data = json.loads(Path(os.path.expanduser(repos_path)).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError("repos.json is unavailable; set the agent's project folder") from error
    entries = data.get("initialized_repos", []) if isinstance(data, dict) else []
    candidates = [entry for entry in entries if _is_aidevops_entry(entry)]
    if not candidates:
        raise RuntimeError(
            "no aidevops repository is registered in repos.json; set the agent's project folder"
        )
    candidates.sort(key=lambda entry: entry["slug"] != AIDEVOPS_UPSTREAM_SLUG)
    return candidates[0]["path"]
