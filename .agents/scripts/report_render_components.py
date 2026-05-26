#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Component block helpers for report Markdown rendering."""

from __future__ import annotations

import html
import re
from collections.abc import Callable

from report_render_markup import inline_markup


COMPONENT_BLOCKS = {
    "action-line", "action-panel", "accordion", "anchor-links", "appendix-links", "callout",
    "case-study-card", "badge-key", "badge-row", "bar-chart", "block-template", "brand-component-grid",
    "brand-swatch-grid", "brand-type-scale", "brief-card", "chapter-hero", "checklist-card",
    "details-note", "dossier-card", "evidence-panel", "example-card", "facts-table-wrap", "good-bad",
    "good-row", "bad-row", "impact-panel", "industry-card", "info-panel", "kpi-card", "ledger-list",
    "manifest-card", "myth-callout", "privacy-note", "priority-card", "priority-group", "quote-card",
    "report-cover", "separator", "severity-key", "source-card", "source-item", "source-list",
    "source-title", "sources-group", "sources-layout", "specimen-card", "stat-card", "summary-stats",
    "stats-strip", "tactic-card", "toc-list", "version-summary", "visibility-bars",
}


def close_component(body: list[str], states: dict[str, object]) -> bool:
    stack = states["components"]
    if not isinstance(stack, list) or not stack:
        return False
    names = states.get("component_names")
    if isinstance(names, list) and names:
        names.pop()
    close_tag = stack.pop()
    body.append(str(close_tag))
    return True


def component_attrs(raw_attrs: str) -> str:
    attrs = []
    for key, raw_value in re.findall(r"([a-zA-Z0-9_-]+)=(\"[^\"]*\"|'[^']*'|[a-zA-Z0-9_#./:-]+)", raw_attrs):
        value = raw_value.strip().strip('"').strip("'")
        if key in {"accent", "priority", "severity", "status"}:
            attrs.append(f' data-{html.escape(key)}="{html.escape(value)}"')
    return "".join(attrs)


def component_title(raw_attrs: str, default: str) -> str:
    match = re.search(r"title=(\"[^\"]*\"|'[^']*'|[^\s]+)", raw_attrs)
    if not match:
        return default
    return match.group(1).strip().strip('"').strip("'") or default


def handle_component(
    line: str,
    body: list[str],
    states: dict[str, object],
    close_blocks: Callable[[list[str], dict[str, object]], None],
) -> bool:
    if line.strip() == ":::":
        close_blocks(body, states)
        close_component(body, states)
        return True
    match = re.match(r"^:::\s+([a-zA-Z0-9_-]+)(.*)$", line)
    if not match or match.group(1) not in COMPONENT_BLOCKS:
        return False
    close_blocks(body, states)
    name = match.group(1)
    raw_attrs = match.group(2)
    if name == "separator":
        body.append('<hr class="section-separator">')
        return True
    close_tag = open_component(name, raw_attrs, body)
    stack = states["components"]
    if isinstance(stack, list):
        stack.append(close_tag)
    names = states.get("component_names")
    if isinstance(names, list):
        names.append(name)
    return True


def open_component(name: str, raw_attrs: str, body: list[str]) -> str:
    if name == "accordion":
        title = component_title(raw_attrs, "Details")
        body.append(f'<details class="accordion" open><summary>{inline_markup(title)}</summary>')
        return "</details>"
    title = component_title(raw_attrs, "")
    body.append(f'<section class="{name}"{component_attrs(raw_attrs)}>')
    if name in {"example-card", "block-template"} and title:
        body.append(f'<header>{inline_markup(title)}</header>')
    return "</section>"
