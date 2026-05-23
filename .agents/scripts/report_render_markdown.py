#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Markdown rendering helpers for report-render-helper.py."""

from __future__ import annotations

import html
import re

from report_render_badges import badge_html
from report_render_markup import inline_markup, slug


def validate_markdown_badges(text: str) -> None:
    for match in re.finditer(r"\{\{\s*evidence\s*:\s*([^}]+?)\s*\}\}", text, re.I):
        badge_html(match.group(1))


COMPONENT_BLOCKS = {
    "action-line",
    "badge-row",
    "chapter-hero",
    "checklist-card",
    "details-note",
    "example-card",
    "facts-table-wrap",
    "good-bad",
    "good-row",
    "bad-row",
    "industry-card",
    "myth-callout",
    "priority-group",
    "report-cover",
    "source-card",
    "stat-card",
    "stats-strip",
    "tactic-card",
}


def close_code(body: list[str], states: dict[str, object]) -> None:
    if not states.get("code"):
        return
    lines = states.get("code_lines", [])
    code_text = "\n".join(lines) if isinstance(lines, list) else ""
    body.append(f"<pre><code>{html.escape(code_text)}</code></pre>")
    states["code"] = False
    states["code_lines"] = []


def close_blocks(body: list[str], states: dict[str, object]) -> None:
    if states.get("code"):
        return
    for key, tag in (("list", "</ul>"), ("table", "</tbody></table>")):
        if states[key]:
            body.append(tag)
            states[key] = False


def close_component(body: list[str], states: dict[str, object]) -> bool:
    stack = states["components"]
    if not isinstance(stack, list) or not stack:
        return False
    body.append("</section>")
    stack.pop()
    return True


def close_all(body: list[str], states: dict[str, object]) -> None:
    close_code(body, states)
    close_blocks(body, states)
    while close_component(body, states):
        pass


def component_attrs(raw_attrs: str) -> str:
    attrs = []
    for key, value in re.findall(r"([a-zA-Z0-9_-]+)=([a-zA-Z0-9_-]+)", raw_attrs):
        if key == "priority":
            attrs.append(f' data-priority="{html.escape(value)}"')
    return "".join(attrs)


def handle_component(line: str, body: list[str], states: dict[str, object]) -> bool:
    if line.strip() == ":::":
        close_blocks(body, states)
        close_component(body, states)
        return True
    match = re.match(r"^:::\s+([a-zA-Z0-9_-]+)(.*)$", line)
    if not match:
        return False
    name = match.group(1)
    if name not in COMPONENT_BLOCKS:
        return False
    close_blocks(body, states)
    body.append(f'<section class="{name}"{component_attrs(match.group(2))}>')
    stack = states["components"]
    if isinstance(stack, list):
        stack.append(name)
    return True


def handle_code_fence(line: str, body: list[str], states: dict[str, object]) -> bool:
    if states.get("code"):
        if line.startswith("```"):
            close_code(body, states)
            return True
        lines = states.get("code_lines", [])
        if isinstance(lines, list):
            lines.append(line)
        return True
    if not line.startswith("```"):
        return False
    close_blocks(body, states)
    states["code"] = True
    states["code_lines"] = []
    return True


def handle_heading(
    line: str,
    headings: list[tuple[int, str, str]],
    body: list[str],
    states: dict[str, object],
) -> bool:
    heading = re.match(r"^(#{1,3})\s+(.+)$", line)
    if not heading:
        return False
    close_blocks(body, states)
    level = len(heading.group(1))
    title = heading.group(2).strip()
    anchor = slug(title)
    headings.append((level, title, anchor))
    body.append(f'<h{level} id="{anchor}">{inline_markup(title)}</h{level}>')
    return True


def handle_table(line: str, body: list[str], states: dict[str, object]) -> bool:
    if not line.startswith("|") or not line.endswith("|"):
        return False
    cells = [inline_markup(cell.strip()) for cell in line.strip("|").split("|")]
    raw_cells = [html.unescape(cell) for cell in cells]
    if all(re.match(r"^:?-{3,}:?$", cell) for cell in raw_cells):
        return True
    if not states["table"]:
        close_blocks(body, states)
        body.append("<table><tbody>")
        states["table"] = True
    body.append("<tr>{}</tr>".format("".join(f"<td>{cell}</td>" for cell in cells)))
    return True


def handle_list(line: str, body: list[str], states: dict[str, object]) -> bool:
    if not line.startswith(("- ", "* ")):
        return False
    if not states["list"]:
        close_blocks(body, states)
        body.append("<ul>")
        states["list"] = True
    body.append(f"<li>{inline_markup(line[2:].strip())}</li>")
    return True


def handle_paragraph(line: str, body: list[str], states: dict[str, object]) -> None:
    close_blocks(body, states)
    if line.lower().startswith(("source:", "source card:")):
        body.append(f'<aside class="source-card">{inline_markup(line)}</aside>')
        return
    body.append(f"<p>{inline_markup(line)}</p>")


def handle_markdown_line(
    line: str,
    headings: list[tuple[int, str, str]],
    body: list[str],
    states: dict[str, object],
) -> None:
    if handle_code_fence(line, body, states):
        return
    if handle_component(line, body, states):
        return
    if handle_heading(line, headings, body, states):
        return
    if handle_table(line, body, states):
        return
    if handle_list(line, body, states):
        return
    handle_paragraph(line, body, states)


def render_markdown(text: str) -> tuple[list[tuple[int, str, str]], str]:
    validate_markdown_badges(text)
    headings: list[tuple[int, str, str]] = []
    body: list[str] = []
    states: dict[str, object] = {"list": False, "table": False, "components": [], "code": False, "code_lines": []}
    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        handle_markdown_line(line, headings, body, states) if line or states.get("code") else close_blocks(body, states)
    close_all(body, states)
    return headings, "\n".join(body)
