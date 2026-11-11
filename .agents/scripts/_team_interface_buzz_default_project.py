"""Default project for Buzz plugin agents that name no project folder."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import json
import os
from pathlib import Path

from _team_interface_buzz_runtime_io import RuntimeError as BuzzRuntimeError


AIDEVOPS_UPSTREAM_SLUG = "marcusquinn/aidevops"


def _rank(entry):
    """Match rank for one repos.json entry: 0 upstream, 1 fork, 2 slugless
    checkout in an `aidevops` folder (slug detection can fail at registration),
    or None when it is not an aidevops checkout."""
    if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
        return None
    slug = entry.get("slug")
    if isinstance(slug, str) and slug:
        if slug == AIDEVOPS_UPSTREAM_SLUG:
            return 0
        return 1 if slug.endswith("/aidevops") else None
    return 2 if Path(entry["path"].rstrip("/")).name == "aidevops" else None


def aidevops_project_root(repos_path):
    """The registered aidevops checkout: upstream slug, then a fork, then a
    slugless `aidevops` folder."""
    try:
        data = json.loads(Path(os.path.expanduser(repos_path)).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BuzzRuntimeError("repos.json is unavailable; set the agent's project folder") from error
    entries = data.get("initialized_repos", []) if isinstance(data, dict) else []
    ranked = [(rank, entry["path"]) for entry in entries if (rank := _rank(entry)) is not None]
    if not ranked:
        raise BuzzRuntimeError(
            "no aidevops repository is registered in repos.json; set the agent's project folder"
        )
    return min(ranked, key=lambda item: item[0])[1]
