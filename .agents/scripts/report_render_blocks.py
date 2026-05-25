#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Block-level Markdown handlers for report rendering."""

from __future__ import annotations

import html
import re

from report_render_markup import inline_markup


def close_blocks(body: list[str], states: dict[str, object]) -> None:
    if states.get("code"):
        return
    flush_paragraph(body, states)
    if states.get("list"):
        tag = states.get("list_tag", "ul")
        body.append(f"</{tag}>")
        states["list"] = False
        states["list_tag"] = ""
    if states.get("table"):
        body.append("</tbody></table>")
        states["table"] = False


def flush_paragraph(body: list[str], states: dict[str, object]) -> None:
    paragraph_lines = states.get("paragraph")
    if not isinstance(paragraph_lines, list) or not paragraph_lines:
        return
    body.append(f"<p>{inline_markup(' '.join(str(line).strip() for line in paragraph_lines))}</p>")
    states["paragraph"] = []


def handle_table(line: str, body: list[str], states: dict[str, object]) -> bool:
    if not line.startswith("|") or not line.endswith("|"):
        return False
    cells = [inline_markup(cell.strip()) for cell in split_markdown_table_row(line)]
    raw_cells = [html.unescape(cell) for cell in cells]
    if all(re.match(r"^:?-{3,}:?$", cell) for cell in raw_cells):
        return True
    if not states["table"]:
        close_blocks(body, states)
        body.append("<table><thead>")
        states["table"] = True
        body.append("<tr>{}</tr></thead><tbody>".format("".join(f"<th>{cell}</th>" for cell in cells)))
        return True
    body.append("<tr>{}</tr>".format("".join(f"<td>{cell}</td>" for cell in cells)))
    return True


def split_markdown_table_row(line: str) -> list[str]:
    row = line.strip()[1:-1]
    cells: list[str] = []
    current: list[str] = []
    index = 0
    while index < len(row):
        char = row[index]
        if char == "|" and _has_odd_trailing_backslashes(current):
            current.pop()
            current.append("|")
        elif char == "|":
            cells.append("".join(current))
            current = []
        else:
            current.append(char)
        index += 1
    cells.append("".join(current))
    return cells


def _has_odd_trailing_backslashes(chars: list[str]) -> bool:
    count = 0
    for char in reversed(chars):
        if char != "\\":
            break
        count += 1
    return count % 2 == 1


def open_list(body: list[str], states: dict[str, object], tag: str, css_class: str = "") -> None:
    if states.get("list") and states.get("list_tag") == tag:
        return
    close_blocks(body, states)
    class_attr = f' class="{css_class}"' if css_class else ""
    body.append(f"<{tag}{class_attr}>")
    states["list"] = True
    states["list_tag"] = tag


def handle_list(line: str, body: list[str], states: dict[str, object]) -> bool:
    checklist = re.match(r"^- \[([ xX])\]\s+(.+)$", line)
    if checklist:
        open_list(body, states, "ul", "checklist")
        status = "done" if checklist.group(1).lower() == "x" else "todo"
        body.append(
            f'<li><span class="status-dot" data-status="{status}"></span><span>{inline_markup(checklist.group(2).strip())}</span></li>'
        )
        return True
    ordered = re.match(r"^\d+\.\s+(.+)$", line)
    if ordered:
        open_list(body, states, "ol")
        body.append(f"<li>{inline_markup(ordered.group(1).strip())}</li>")
        return True
    if line.startswith(("- ", "* ")):
        open_list(body, states, "ul")
        body.append(f"<li>{inline_markup(line[2:].strip())}</li>")
        return True
    return False


def handle_blockquote(line: str, body: list[str], states: dict[str, object]) -> bool:
    if not line.startswith("> "):
        return False
    close_blocks(body, states)
    body.append(f'<blockquote>{inline_markup(line[2:].strip())}</blockquote>')
    return True
