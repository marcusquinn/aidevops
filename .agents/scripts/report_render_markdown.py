#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Markdown rendering helpers for report-render-helper.py."""

from __future__ import annotations

import re

from report_render_badges import badge_html
from report_render_markup import inline_markup, slug

BlockState = dict[str, bool | list[str]]


def validate_markdown_badges(text: str) -> None:
    for match in re.finditer(r"\{\{\s*evidence\s*:\s*([^}]+?)\s*\}\}", text, re.I):
        badge_html(match.group(1))


def close_blocks(body: list[str], states: BlockState) -> None:
    flush_paragraph(body, states)
    for key, tag in (("list", "</ul>"), ("table", "</tbody></table>")):
        if states[key]:
            body.append(tag)
            states[key] = False


def flush_paragraph(body: list[str], states: BlockState) -> None:
    paragraph_lines = states["paragraph"]
    if not isinstance(paragraph_lines, list) or not paragraph_lines:
        return
    body.append(f"<p>{inline_markup(' '.join(paragraph_lines))}</p>")
    states["paragraph"] = []


def handle_heading(
    line: str,
    headings: list[tuple[int, str, str]],
    body: list[str],
    states: BlockState,
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


def handle_table(line: str, body: list[str], states: BlockState) -> bool:
    if not line.startswith("|") or not line.endswith("|"):
        return False
    raw_cells = [cell.strip() for cell in line.strip("|").split("|")]
    if all(re.match(r"^:?-{3,}:?$", cell) for cell in raw_cells):
        return True
    cells = [inline_markup(cell) for cell in raw_cells]
    if not states["table"]:
        close_blocks(body, states)
        body.append("<table><thead>")
        body.append("<tr>{}</tr>".format("".join(f"<th>{cell}</th>" for cell in cells)))
        body.append("</thead><tbody>")
        states["table"] = True
        return True
    body.append("<tr>{}</tr>".format("".join(f"<td>{cell}</td>" for cell in cells)))
    return True


def handle_list(line: str, body: list[str], states: BlockState) -> bool:
    if not line.startswith(("- ", "* ")):
        return False
    if not states["list"]:
        close_blocks(body, states)
        body.append("<ul>")
        states["list"] = True
    body.append(f"<li>{inline_markup(line[2:].strip())}</li>")
    return True


def handle_paragraph(line: str, body: list[str], states: BlockState) -> None:
    if states["list"] or states["table"]:
        close_blocks(body, states)
    if line.lower().startswith(("source:", "source card:")):
        flush_paragraph(body, states)
        body.append(f'<aside class="source-card">{inline_markup(line)}</aside>')
        return
    paragraph_lines = states["paragraph"]
    if isinstance(paragraph_lines, list):
        paragraph_lines.append(line)


def handle_markdown_line(
    line: str,
    headings: list[tuple[int, str, str]],
    body: list[str],
    states: BlockState,
) -> None:
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
    states = {"list": False, "table": False, "paragraph": []}
    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        handle_markdown_line(line, headings, body, states) if line else close_blocks(body, states)
    close_blocks(body, states)
    return headings, "\n".join(body)
