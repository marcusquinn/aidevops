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


def aidevops_project_root(repos_path, validate):
    """The first registered aidevops checkout that `validate(path, repos_path)`
    accepts, trying upstream slug, then forks, then slugless `aidevops`
    folders. Paths are resolved first, so a symlinked registration validates,
    and a stale registration falls through to the next candidate."""
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
    last_error = None
    for _rank_value, path in sorted(ranked, key=lambda item: item[0]):
        try:
            return validate(os.path.realpath(os.path.expanduser(path)), repos_path)
        except BuzzRuntimeError as error:
            last_error = error
    raise BuzzRuntimeError(
        "no registered aidevops repository is usable; set the agent's project folder"
    ) from last_error
