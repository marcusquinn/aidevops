# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""YAML frontmatter rendering/update for extracted entities."""

from __future__ import annotations

import sys
from pathlib import Path

from entity_cleaners import ENTITY_TYPES
from email_shared import extract_frontmatter, yaml_escape


def entities_to_yaml(entities: dict[str, list[str]], indent: int = 0) -> str:
    """Convert entities dict to YAML frontmatter fragment."""
    prefix = " " * indent
    if not entities:
        return f"{prefix}entities: {{}}"

    lines = [f"{prefix}entities:"]
    for entity_type in ENTITY_TYPES:
        if entity_type in entities and entities[entity_type]:
            lines.append(f"{prefix}  {entity_type}:")
            for entity in entities[entity_type]:
                escaped = yaml_escape(entity)
                lines.append(f"{prefix}    - {escaped}")

    return "\n".join(lines)


def update_frontmatter(file_path: str, entities: dict[str, list[str]]) -> bool:
    """Update a markdown file's YAML frontmatter with entities.

    Adds or replaces the `entities:` field in existing frontmatter.
    Returns True if the file was modified.
    """
    path = Path(file_path)
    content = path.read_text(encoding="utf-8")

    opener, fm_content, body = extract_frontmatter(content)
    if not opener:
        print(f"WARNING: No YAML frontmatter in {file_path}", file=sys.stderr)
        return False

    fm_lines = fm_content.split("\n")
    new_fm_lines = []
    skip_block = False
    for line in fm_lines:
        if line.startswith("entities:"):
            skip_block = True
            continue
        if skip_block:
            if line.startswith("  ") or line.startswith("\t"):
                continue
            skip_block = False
        new_fm_lines.append(line)

    entities_yaml = entities_to_yaml(entities)
    new_fm_lines.append(entities_yaml)

    new_fm = "\n".join(new_fm_lines)
    new_content = f"---\n{new_fm}\n---{body}"

    path.write_text(new_content, encoding="utf-8")
    return True
