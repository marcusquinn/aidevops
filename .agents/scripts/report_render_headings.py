#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Heading helpers for report Markdown rendering."""

from __future__ import annotations

import re
from collections.abc import Callable

from report_render_markup import inline_markup, slug


def plain_heading_title(title: str) -> str:
    cleaned = re.sub(r"\{\{\s*(?:badge|evidence)\s*:[^}]+?\s*\}\}", "", title, flags=re.I)
    return " ".join(cleaned.split())


def is_executive_summary(title: str) -> bool:
    return plain_heading_title(title).lower() == "executive summary"


def handle_heading(
    line: str,
    headings: list[tuple[int, str, str]],
    body: list[str],
    states: dict[str, object],
    close_blocks: Callable[[list[str], dict[str, object]], None],
) -> bool:
    heading = re.match(r"^(#{1,3})\s+(.+)$", line)
    if not heading:
        return False
    close_blocks(body, states)
    level = len(heading.group(1))
    title = heading.group(2).strip()
    anchor = slug(title)
    display_title, classes = heading_display(level, title, states)
    class_attr = f' class="{" ".join(classes)}"' if classes else ""
    headings.append((level, title, anchor))
    body.append(f'<h{level}{class_attr} id="{anchor}">{display_title}</h{level}>')
    return True


def heading_display(level: int, title: str, states: dict[str, object]) -> tuple[str, list[str]]:
    classes: list[str] = []
    display_title = inline_markup(title)
    if level == 2:
        display_title = h2_display(title, states, classes)
    elif level == 3 and int(states.get("chapter_count", 0)) > 0:
        classes.append("section-heading")
        section_count = int(states.get("section_count", 0)) + 1
        states["section_count"] = section_count
        display_title = f'<span class="heading-number">{states["chapter_count"]}.{section_count}</span> {inline_markup(title)}'
    return display_title, classes


def h2_display(title: str, states: dict[str, object], classes: list[str]) -> str:
    if is_executive_summary(title):
        classes.append("no-chapter")
        states["chapter_count"] = int(states.get("chapter_count", 0))
        states["section_count"] = 0
        return inline_markup(title)
    classes.append("chapter-heading")
    chapter_count = int(states.get("chapter_count", 0)) + 1
    states["chapter_count"] = chapter_count
    states["section_count"] = 0
    return f'<span class="heading-number">{chapter_count}.</span> {inline_markup(title)}'
