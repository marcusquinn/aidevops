#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email_frontmatter_utils.py - YAML frontmatter parsing and update utilities.

Extracted from email-thread-reconstruction.py to reduce file-level complexity.
Shared between email thread reconstruction, manifest generation, and other
email pipeline scripts.
"""

import re


def _extract_frontmatter_text(content: str):
    """Extract the raw frontmatter text from markdown content.

    Returns the frontmatter text string, or None if not found.
    """
    if not content.startswith("---\n"):
        return None
    end_match = re.search(r"\n---\n", content[4:])
    if not end_match:
        return None
    return content[4 : 4 + end_match.start()]


def _parse_frontmatter_line(line: str):
    """Parse a single frontmatter line into (key, value) or None."""
    if ":" not in line or line.startswith("  "):
        return None
    key, _, value = line.partition(":")
    key = key.strip()
    value = value.strip()
    if value.startswith('"') and value.endswith('"'):
        value = value[1:-1]
    return key, value


def parse_frontmatter(md_file):
    """Extract YAML frontmatter from a markdown file.

    Returns dict of metadata, or None if no frontmatter found.
    """
    with open(md_file, "r", encoding="utf-8") as f:
        content = f.read()

    frontmatter_text = _extract_frontmatter_text(content)
    if frontmatter_text is None:
        return None

    metadata = {}
    for line in frontmatter_text.split("\n"):
        parsed = _parse_frontmatter_line(line)
        if parsed is not None:
            key, value = parsed
            metadata[key] = value

    return metadata


def _format_field(key, value):
    """Format a YAML frontmatter field as 'key: value' string."""
    if isinstance(value, str):
        return f'{key}: "{value}"'
    return f"{key}: {value}"


def _find_insert_point(lines):
    """Find insertion point for new fields (after tokens_estimate or at end)."""
    for i, line in enumerate(lines):
        if line.startswith("tokens_estimate:"):
            return i + 1
    return len(lines)


def _update_existing_field(lines, key, value):
    """Update an existing field in frontmatter lines. Returns True if found."""
    for i, line in enumerate(lines):
        if line.startswith(f"{key}:"):
            lines[i] = _format_field(key, value)
            return True
    return False


def _split_frontmatter_body(content: str):
    """Split markdown content into (frontmatter_text, body, frontmatter_end).

    Returns (None, None, None) if no valid frontmatter found.
    """
    if not content.startswith("---\n"):
        return None, None, None
    end_match = re.search(r"\n---\n", content[4:])
    if not end_match:
        return None, None, None
    frontmatter_end = 4 + end_match.start() + 5  # +5 for '\n---\n'
    frontmatter_text = content[4 : 4 + end_match.start()]
    body = content[frontmatter_end:]
    return frontmatter_text, body, frontmatter_end


def _apply_new_fields(lines: list, new_fields: dict) -> list:
    """Update existing fields and collect new ones for insertion."""
    new_lines = []
    for key, value in new_fields.items():
        if not _update_existing_field(lines, key, value):
            new_lines.append(_format_field(key, value))
    if new_lines:
        insert_idx = _find_insert_point(lines)
        lines = lines[:insert_idx] + new_lines + lines[insert_idx:]
    return lines


def update_frontmatter(md_file, new_fields):
    """Update frontmatter in a markdown file with new fields.

    Adds or updates fields in the YAML frontmatter section.
    """
    with open(md_file, "r", encoding="utf-8") as f:
        content = f.read()

    frontmatter_text, body, _ = _split_frontmatter_body(content)
    if frontmatter_text is None:
        return False

    lines = _apply_new_fields(frontmatter_text.split("\n"), new_fields)
    new_content = "---\n" + "\n".join(lines) + "\n---\n" + body

    with open(md_file, "w", encoding="utf-8") as f:
        f.write(new_content)

    return True
