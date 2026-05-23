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


def inline_markup(text: str) -> str:
    escaped = html.escape(text)
    escaped = re.sub(
        r"\{\{\s*evidence\s*:\s*([^}]+?)\s*\}\}",
        lambda match: badge_html(html.unescape(match.group(1))),
        escaped,
        flags=re.I,
    )
    escaped = re.sub(r"`([^`]+)`", r"<code>\1</code>", escaped)
    return re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", escaped)
