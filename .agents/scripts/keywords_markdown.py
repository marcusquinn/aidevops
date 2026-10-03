#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Small Markdown parsing helpers for legacy keyword context files."""

from __future__ import annotations

import re

METRIC_RE = re.compile(r"\((?P<body>[^)]*)\)")
METRIC_FIELDS = {"vol": "volume", "volume": "volume", "difficulty": "kd", "kd": "kd"}


def placeholder(text: str) -> bool:
    """True for empty values and unfilled template tokens such as [keyword]."""
    stripped = text.strip()
    return not stripped or stripped.startswith("[") or bool(re.search(r"\[[^\]]+\]", stripped))


def split_items(value: str) -> list[str]:
    """Split on commas that are not inside parentheses."""
    items: list[str] = []
    depth = 0
    current: list[str] = []
    for char in value:
        depth += (char == "(") - (char == ")")
        if char == "," and depth == 0:
            items.append("".join(current).strip())
            current = []
            continue
        current.append(char)
    items.append("".join(current).strip())
    return [item for item in items if item]


def parse_item(item: str) -> dict[str, str]:
    """'running shoes (volume: 1,200, difficulty: 64)' -> phrase + numeric metrics."""
    metrics: dict[str, str] = {}
    match = METRIC_RE.search(item)
    for part in (match.group("body").split(",") if match else []):
        key, _, value = part.partition(":")
        field = METRIC_FIELDS.get(key.strip().lower())
        number = re.sub(r"[^\d.]", "", value)
        if field and number:
            metrics[field] = number
    return {"phrase": METRIC_RE.sub("", item).strip(), **metrics}


def _cells(line: str) -> list[str]:
    stripped = line.strip()
    return [cell.strip() for cell in stripped.strip("|").split("|")] if stripped.startswith("|") else []


def _separator(cells: list[str]) -> bool:
    return set(cells[0]) <= {"-", ":"}


def _table_body(lines: list[list[str]], start: int) -> list[list[str]]:
    body: list[list[str]] = []
    for cells in lines[start + 1:]:
        if not cells:
            break
        body.append(cells)
    return body


def _is_header(cells: list[str], first_header: str) -> bool:
    return bool(cells) and cells[0].lower() == first_header


def table_rows(text: str, first_header: str) -> list[list[str]]:
    """Body rows of the first Markdown table whose first header matches."""
    lines = [_cells(line) for line in text.splitlines()]
    start = next((index for index, cells in enumerate(lines) if _is_header(cells, first_header)), None)
    if start is None:
        return []
    return [row for row in _table_body(lines, start) if not _separator(row) and not placeholder(row[0])]
