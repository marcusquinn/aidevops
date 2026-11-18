# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Rename legacy generated ``Buzz`` Tabby profiles (GH#39038).

The Buzz workspace is not a Git repository, so its profile must not read like a
repo profile. Only managed profiles still named exactly ``Buzz`` at the
workspace cwd are renamed; user-renamed profiles are left untouched.
"""

import os
import re
from typing import Callable

from tabby_yaml_helpers import (
    ProfileBlock,
    extract_group_id,
    extract_profile_blocks,
    validate_yaml_document,
)

LEGACY_BUZZ_PROFILE_NAME = "Buzz"
BUZZ_PROFILE_NAME = "Buzz agent sessions (not a repo)"

_NAME_LINE = re.compile(
    r"^(?P<lead>\s*(?:-\s+)?name:\s*)(?P<value>.*?)(?P<nl>\r?\n)?$"
)


def _normalize(path: str) -> str:
    return os.path.normcase(os.path.realpath(os.path.expanduser(path)))


def _block_cwd(profile: dict) -> str | None:
    options = profile.get("options")
    cwd = options.get("cwd") if isinstance(options, dict) else None
    return cwd if isinstance(cwd, str) else None


def _is_legacy_buzz(
    block: ProfileBlock,
    target: str,
    group_id: str | None,
    is_managed: Callable[[dict, str | None], bool],
) -> bool:
    profile = block.data
    cwd = _block_cwd(profile)
    return all(
        (
            cwd is not None and _normalize(cwd) == target,
            profile.get("name") == LEGACY_BUZZ_PROFILE_NAME,
            is_managed(profile, group_id),
        )
    )


def _rename_name_line(lines: list[str], block: ProfileBlock) -> bool:
    for index in range(block.start, block.end):
        match = _NAME_LINE.match(lines[index])
        if match and match.group("value").strip("'\" ") == LEGACY_BUZZ_PROFILE_NAME:
            newline = match.group("nl") or ""
            lines[index] = f"{match.group('lead')}{BUZZ_PROFILE_NAME}{newline}"
            return True
    return False


def rename_legacy_buzz_profiles(
    config_text: str,
    buzz_path: str,
    is_managed: Callable[[dict, str | None], bool],
) -> tuple[str, int]:
    """Return (config_text, renamed_count) for legacy managed Buzz profiles."""
    group_id = extract_group_id(config_text)
    target = _normalize(buzz_path)
    lines = config_text.splitlines(keepends=True)
    renamed = sum(
        _rename_name_line(lines, block)
        for block in extract_profile_blocks(config_text)
        if _is_legacy_buzz(block, target, group_id, is_managed)
    )
    if not renamed:
        return config_text, 0
    updated = "".join(lines)
    validate_yaml_document(updated)
    return updated, renamed
