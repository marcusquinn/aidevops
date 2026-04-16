#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
YAML parsing and insertion helpers for tabby-profile-sync.py.

Extracted from tabby-profile-sync.py to reduce file complexity.
Handles Tabby config.yaml reading, existing profile detection,
and new profile/group insertion.
"""

from __future__ import annotations

import re
from typing import Optional


def load_yaml_simple(path: str) -> str:
    """Load file content as string."""
    with open(path, "r") as f:
        return f.read()


def save_yaml(path: str, content: str) -> None:
    """Save content to file."""
    with open(path, "w") as f:
        f.write(content)


def extract_existing_cwds(config_text: str) -> set[str]:
    """Extract all cwd paths from existing profiles."""
    cwds = set()
    # Match cwd: lines in profile blocks
    for match in re.finditer(r"^\s+cwd:\s+(.+)$", config_text, re.MULTILINE):
        cwd = match.group(1).strip().strip("'\"")
        cwds.add(cwd)
    return cwds


def extract_group_id(config_text: str) -> Optional[str]:
    """Find the 'Projects' group ID, or return None."""
    # Look for groups section — capture all indented content after "groups:"
    groups_match = re.search(
        r"^groups:\s*\n((?:[ \t]+.*\n)*)", config_text, re.MULTILINE
    )
    if not groups_match:
        return None

    # Parse group entries by accumulating blocks (each starts with "  - ")
    group_block = groups_match.group(1)
    blocks: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for line in group_block.split("\n"):
        if not line.strip():
            continue
        # New group entry starts with "  - " (list item)
        if re.match(r"\s+-\s+", line):
            if current:
                blocks.append(current)
            current = {}
            # The first field may be on the same line as "-"
            line = re.sub(r"^\s+-\s+", "  ", line)
        # Extract key: value pairs
        kv_match = re.match(r"\s+(\w+):\s+(.+)", line)
        if kv_match:
            current[kv_match.group(1)] = kv_match.group(2).strip().strip("'\"")
    if current:
        blocks.append(current)

    # Find the "Projects" group
    for block in blocks:
        if block.get("name") == "Projects" and "id" in block:
            return block["id"]
    return None


def find_profiles_insert_line(lines: list[str]) -> tuple[bool, Optional[int]]:
    """Find where to insert new profiles in the YAML lines.

    Returns (has_profiles_key, insert_line).
    """
    has_profiles_key = False
    in_profiles = False
    insert_line = None
    for i, line in enumerate(lines):
        if re.match(r"^profiles:", line):
            has_profiles_key = True
            in_profiles = True
            continue
        if in_profiles and re.match(r"^[a-zA-Z]", line):
            insert_line = i
            break
    return has_profiles_key, insert_line


def find_version_insert_at(lines: list[str]) -> int:
    """Find the line index after the version: line, or 0 if not found."""
    for i, line in enumerate(lines):
        if re.match(r"^version:", line):
            return i + 1
    return 0


def insert_profiles_block(config_text: str, new_block: str) -> str:
    """Insert new_block into the profiles section of config_text."""
    lines = config_text.split("\n")
    has_profiles_key, insert_line = find_profiles_insert_line(lines)

    if not has_profiles_key:
        insert_at = find_version_insert_at(lines)
        lines.insert(insert_at, f"profiles:\n{new_block}")
    else:
        if insert_line is None:
            insert_line = len(lines)
        lines.insert(insert_line, new_block)

    return "\n".join(lines)
