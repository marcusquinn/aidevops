#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared inline markup helpers for report rendering."""

from __future__ import annotations

import html
import re

from report_render_badges import badge_html


def slug(text: str) -> str:
    value = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return value or "section"


def safe_href(value: str) -> str:
    href = html.unescape(value).strip()
    if re.match(r"(?i)^(javascript|data):", href):
        return ""
    return href


def inline_markup(text: str) -> str:
    escaped = html.escape(text)
    escaped = re.sub(
        r"\{\{\s*evidence\s*:\s*([^}]+?)\s*\}\}",
        lambda match: badge_html(html.unescape(match.group(1))),
        escaped,
        flags=re.I,
    )
    escaped = re.sub(r"`([^`]+)`", r"<code>\1</code>", escaped)
    escaped = re.sub(
        r"\[([^\]]+)\]\(([^)]+)\)",
        lambda match: f'<a href="{html.escape(safe_href(match.group(2)))}">{match.group(1)}</a>'
        if safe_href(match.group(2))
        else match.group(1),
        escaped,
    )
    return re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", escaped)
