#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared inline markup helpers for report rendering."""

from __future__ import annotations

import html
import re

from report_render_badges import badge_html

BADGE_CLASS_MAP = {
    "rct": "badge--rct",
    "strong": "badge--strong",
    "vendor": "badge--vendor",
    "practitioner": "badge--practitioner",
    "hygiene": "badge--hygiene",
    "critical": "badge-missing",
    "high": "badge-partial",
    "medium": "badge-inferred",
    "low": "badge-verified",
}

BADGE_LABEL_MAP = {
    "rct": "Peer-Review",
}


def slug(text: str) -> str:
    value = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return value or "section"


def safe_href(value: str) -> str:
    href = html.unescape(value).strip()
    if re.match(r"(?i)^(javascript|data):", href):
        return ""
    return href


def file_type(value: str) -> str:
    href = safe_href(value).split("#", 1)[0].split("?", 1)[0]
    if "." not in href.rsplit("/", 1)[-1]:
        return "link"
    suffix = href.rsplit(".", 1)[-1].lower()
    return suffix[:6] or "file"


def link_html(label: str, href_value: str) -> str:
    href = safe_href(href_value)
    if not href:
        return label
    return f'<a href="{html.escape(href)}" data-filetype="{html.escape(file_type(href))}">{label}</a>'


def generic_badge(value: str) -> str:
    raw = html.unescape(value).strip()
    key = re.sub(r"[^a-z0-9]+", "-", raw.lower()).strip("-") or "note"
    css_class = BADGE_CLASS_MAP.get(key, "badge--hygiene")
    label = html.escape(BADGE_LABEL_MAP.get(key, raw.replace("-", " ").title()))
    return f'<span class="badge {css_class}">{label}</span>'


def inline_markup(text: str) -> str:
    escaped = html.escape(text)
    escaped = re.sub(
        r"\{\{\s*evidence\s*:\s*([^}]+?)\s*\}\}",
        lambda match: badge_html(html.unescape(match.group(1))),
        escaped,
        flags=re.I,
    )
    escaped = re.sub(
        r"\{\{\s*badge\s*:\s*([^}]+?)\s*\}\}",
        lambda match: generic_badge(match.group(1)),
        escaped,
        flags=re.I,
    )
    escaped = re.sub(
        r"\{\{\s*latex\s*:\s*([^}]+?)\s*\}\}",
        lambda match: (
            '<span class="latex-inline" role="math" '
            f'aria-label="{html.escape(html.unescape(match.group(1)))}">'
            f'{html.escape(html.unescape(match.group(1)))}</span>'
        ),
        escaped,
        flags=re.I,
    )
    escaped = re.sub(r"`([^`]+)`", r"<code>\1</code>", escaped)
    escaped = re.sub(
        r"\[([^\]]+)\]\(([^)]+)\)",
        lambda match: link_html(match.group(1), match.group(2)),
        escaped,
    )
    return re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", escaped)
