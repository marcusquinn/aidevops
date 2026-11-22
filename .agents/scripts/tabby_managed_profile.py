# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Identify aidevops-generated Tabby profiles."""

from __future__ import annotations

import uuid

from tabby_profile_utils import (
    LEGACY_TABBY_COMMAND_FIELD_OPENCODE,
    LEGACY_TABBY_OPENCODE_LAUNCH,
    TABBY_COMMAND_FIELD_OPENCODE,
    TABBY_OPENCODE_LAUNCH,
)


def _has_managed_profile_id(profile: dict) -> bool:
    """Return True only for IDs emitted by :func:`build_profile_yaml`."""
    profile_id = profile.get("id")
    if not isinstance(profile_id, str):
        return False
    try:
        uuid.UUID(profile_id.rsplit(":", 1)[1])
    except (ValueError, IndexError):
        return False
    return profile_id.startswith("local:custom:")


def _has_managed_launch(options: dict) -> bool:
    """Return True for current and historical aidevops OpenCode launch forms."""
    args = options.get("args")
    managed_args = (
        ["-l", "-c", TABBY_OPENCODE_LAUNCH],
        ["-l", "-c", "aidevops opencode; exec zsh"],
        ["-l", "-c", LEGACY_TABBY_OPENCODE_LAUNCH],
        ["-l", "-i", "-c", "opencode"],
    )
    command = options.get("command")
    managed_commands = (
        TABBY_COMMAND_FIELD_OPENCODE,
        LEGACY_TABBY_COMMAND_FIELD_OPENCODE,
        "/bin/zsh -l -c 'aidevops opencode; exec zsh'",
    )
    return any((args in managed_args, command in managed_commands))


def is_aidevops_managed_profile(profile: dict, projects_group_id: str | None) -> bool:
    """Identify a generated profile without claiming custom OpenCode profiles."""
    options = profile.get("options")
    if not isinstance(options, dict):
        return False
    return all(
        (
            projects_group_id,
            profile.get("group") == projects_group_id,
            profile.get("type") == "local",
            isinstance(options.get("cwd"), str),
            _has_managed_profile_id(profile),
            _has_managed_launch(options),
        )
    )
