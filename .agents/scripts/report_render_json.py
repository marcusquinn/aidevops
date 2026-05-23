#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""JSON rendering helpers for report-render-helper.py."""

from __future__ import annotations

import json
from typing import Any

from report_render_badges import BADGE_KEY, badge_html
from report_render_markup import inline_markup, slug

TITLE_KEY = "title"
DETAIL_KEY = "detail"
SUMMARY_KEY = "summary"


def validate_json_badges(node: Any) -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            badge_html(value) if key in (BADGE_KEY, "evidenceBadge") else None
            validate_json_badges(value)
        return
    if isinstance(node, list):
        for item in node:
            validate_json_badges(item)


def append_json_item(body: list[str], item: dict[str, Any]) -> None:
    badge = f" {badge_html(item[BADGE_KEY])}" if item.get(BADGE_KEY) else ""
    item_title = inline_markup(str(item.get(TITLE_KEY, "Item")))
    detail = inline_markup(str(item.get(DETAIL_KEY, "")))
    body.append(f'<div class="source-card"><strong>{item_title}</strong>{badge}<p>{detail}</p></div>')


def append_json_section(
    headings: list[tuple[int, str, str]],
    body: list[str],
    section: dict[str, Any],
) -> None:
    section_title = section.get(TITLE_KEY, "Section")
    headings.append((2, section_title, slug(section_title)))
    body.append(f'<h2 id="{slug(section_title)}">{inline_markup(section_title)}</h2>')
    if section.get(SUMMARY_KEY):
        body.append(f"<p>{inline_markup(str(section[SUMMARY_KEY]))}</p>")
    for item in section.get("items", []):
        append_json_item(body, item)


def render_json(text: str) -> tuple[list[tuple[int, str, str]], str]:
    data = json.loads(text)
    validate_json_badges(data)
    headings: list[tuple[int, str, str]] = []
    body: list[str] = []
    title = data.get(TITLE_KEY, "Report") if isinstance(data, dict) else "Report"
    headings.append((1, title, slug(title)))
    body.append(f'<h1 id="{slug(title)}">{inline_markup(title)}</h1>')
    for section in data.get("sections", []):
        append_json_section(headings, body, section)
    return headings, "\n".join(body)
