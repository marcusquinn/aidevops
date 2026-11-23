# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact cwd retargeting for Tabby profile YAML text."""

from __future__ import annotations

import re

from tabby_yaml_helpers import _parse_block_scalar, validate_yaml_document


def _retarget_block_cwd(
    lines: list[str],
    index: int,
    match: re.Match[str],
    raw_value: str,
    path_mappings: dict[str, str],
) -> tuple[int, bool]:
    """Retarget one block-scalar cwd and return the next line index."""
    parent_indent = len(match.group("indent"))
    value, next_index = _parse_block_scalar(
        [line.rstrip("\r\n") for line in lines],
        index + 1,
        parent_indent,
        raw_value[0],
    )
    replacement = path_mappings.get(value)
    if not replacement:
        return next_index, False

    lines[index] = (
        f"{match.group('indent')}cwd: {replacement}"
        f"{match.group('newline') or ''}"
    )
    del lines[index + 1 : next_index]
    return index + 1, True


def _retarget_inline_cwd(
    match: re.Match[str], raw_value: str, path_mappings: dict[str, str]
) -> str | None:
    """Render a retargeted inline cwd line, preserving matching quotes."""
    quoted_value = re.fullmatch(r"(?P<quote>['\"])(?P<value>.*)(?P=quote)", raw_value)
    quote = quoted_value.group("quote") if quoted_value else ""
    value = quoted_value.group("value") if quoted_value else raw_value
    replacement = path_mappings.get(value)
    if not replacement:
        return None

    rendered = f"{quote}{replacement}{quote}" if quote else replacement
    return (
        f"{match.group('indent')}cwd: {rendered}"
        f"{match.group('newline') or ''}"
    )


def _retarget_cwd_line(
    lines: list[str],
    index: int,
    cwd_pattern: re.Pattern[str],
    path_mappings: dict[str, str],
) -> tuple[int, bool]:
    """Retarget the cwd at one line and return the next index and change flag."""
    match = cwd_pattern.match(lines[index])
    if not match:
        return index + 1, False
    raw_value = match.group("value").strip()
    if raw_value.startswith((">", "|")):
        return _retarget_block_cwd(lines, index, match, raw_value, path_mappings)
    retargeted_line = _retarget_inline_cwd(match, raw_value, path_mappings)
    if not retargeted_line:
        return index + 1, False
    lines[index] = retargeted_line
    return index + 1, True


def retarget_profile_cwds(
    config_text: str, path_mappings: dict[str, str]
) -> tuple[str, int]:
    """Retarget exact profile cwd scalars without changing unrelated bytes."""
    validate_yaml_document(config_text)
    lines = config_text.splitlines(keepends=True)
    changed = 0
    index = 0
    cwd_pattern = re.compile(r"^(?P<indent>\s+)cwd:\s*(?P<value>.*?)(?P<newline>\r?\n)?$")
    while index < len(lines):
        index, was_retargeted = _retarget_cwd_line(
            lines, index, cwd_pattern, path_mappings
        )
        changed += was_retargeted
    updated = "".join(lines)
    validate_yaml_document(updated)
    return updated, changed
