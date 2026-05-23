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
    "action-panel",
    "accordion",
    "anchor-links",
    "appendix-links",
    "callout",
    "case-study-card",
    "badge-key",
    "badge-row",
    "bar-chart",
    "block-template",
    "chapter-hero",
    "checklist-card",
    "details-note",
    "evidence-panel",
    "example-card",
    "facts-table-wrap",
    "good-bad",
    "good-row",
    "bad-row",
    "impact-panel",
    "industry-card",
    "info-panel",
    "myth-callout",
    "priority-group",
    "quote-card",
    "report-cover",
    "separator",
    "severity-key",
    "source-card",
    "source-item",
    "source-list",
    "source-title",
    "sources-group",
    "sources-layout",
    "stat-card",
    "summary-stats",
    "stats-strip",
    "tactic-card",
    "version-summary",
}


def plain_heading_title(title: str) -> str:
    cleaned = re.sub(r"\{\{\s*(?:badge|evidence)\s*:[^}]+?\s*\}\}", "", title, flags=re.I)
    return " ".join(cleaned.split())


def is_executive_summary(title: str) -> bool:
    return plain_heading_title(title).lower() == "executive summary"


def render_mermaid_svg(code_text: str) -> str:
    """Render a small self-contained SVG for simple Mermaid flowchart examples."""

    nodes: list[str] = []
    for line in code_text.splitlines():
        if "-->" not in line:
            continue
        left, right = [part.strip() for part in line.split("-->", 1)]
        for node in (left, right):
            label = re.sub(r"^[A-Za-z0-9_]+\[([^\]]+)\]$", r"\1", node).strip()
            if label and label not in nodes:
                nodes.append(label)
    if len(nodes) < 2:
        return ""
    width = max(720, len(nodes) * 190)
    height = 130
    gap = width // max(len(nodes), 1)
    boxes = []
    arrows = []
    for index, label in enumerate(nodes):
        x = 24 + index * gap
        y = 35
        safe_label = html.escape(label)
        boxes.append(
            f'<rect x="{x}" y="{y}" width="145" height="56" rx="14" class="diagram-node" />'
            f'<text x="{x + 72}" y="{y + 34}" text-anchor="middle" class="diagram-label">{safe_label}</text>'
        )
        if index < len(nodes) - 1:
            arrows.append(
                f'<line x1="{x + 150}" y1="{y + 28}" x2="{x + gap - 8}" y2="{y + 28}" class="diagram-arrow" />'
            )
    return (
        '<figure class="mermaid-rendered" aria-label="Rendered Mermaid diagram">'
        f'<svg viewBox="0 0 {width} {height}" role="img" xmlns="http://www.w3.org/2000/svg">'
        '<defs><marker id="arrowhead" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto">'
        '<polygon points="0 0, 10 3.5, 0 7" class="diagram-arrow-head" /></marker></defs>'
        f'{"".join(arrows)}{"".join(boxes)}</svg>'
        '<figcaption>Rendered Mermaid example, embedded as self-contained SVG.</figcaption>'
        '</figure>'
    )


def render_latex_block(code_text: str) -> str:
    formula = " ".join(code_text.split())
    if not formula:
        return ""
    return (
        '<figure class="latex-rendered-block" aria-label="Rendered LaTeX formula">'
        f'<div role="math" aria-label="{html.escape(formula)}">{html.escape(formula)}</div>'
        '<figcaption>Rendered LaTeX example, embedded as self-contained HTML.</figcaption>'
        '</figure>'
    )


def close_code(body: list[str], states: dict[str, object]) -> None:
    if not states.get("code"):
        return
    lines = states.get("code_lines", [])
    code_text = "\n".join(lines) if isinstance(lines, list) else ""
    lang = str(states.get("code_lang", "")).strip().lower()
    if lang == "mermaid":
        body.append(
            '<div class="code-block-wrap">'
            '<button class="code-copy" type="button" aria-label="Copy code" title="Copy code">⧉</button>'
            f'<pre class="mermaid"><code>{html.escape(code_text)}</code></pre></div>'
        )
        rendered = render_mermaid_svg(code_text)
        if rendered:
            body.append(rendered)
    elif lang in {"latex", "tex"}:
        body.append(
            '<div class="code-block-wrap">'
            '<button class="code-copy" type="button" aria-label="Copy code" title="Copy code">⧉</button>'
            f'<pre class="latex-block"><code>{html.escape(code_text)}</code></pre></div>'
        )
        rendered = render_latex_block(code_text)
        if rendered:
            body.append(rendered)
    else:
        body.append(
            '<div class="code-block-wrap">'
            '<button class="code-copy" type="button" aria-label="Copy code" title="Copy code">⧉</button>'
            f"<pre><code>{html.escape(code_text)}</code></pre></div>"
        )
    states["code"] = False
    states["code_lines"] = []
    states["code_lang"] = ""


def close_blocks(body: list[str], states: dict[str, object]) -> None:
    if states.get("code"):
        return
    if states.get("list"):
        tag = states.get("list_tag", "ul")
        body.append(f"</{tag}>")
        states["list"] = False
        states["list_tag"] = ""
    if states.get("table"):
        body.append("</tbody></table>")
        states["table"] = False


def close_component(body: list[str], states: dict[str, object]) -> bool:
    stack = states["components"]
    if not isinstance(stack, list) or not stack:
        return False
    close_tag = stack.pop()
    body.append(str(close_tag))
    return True


def close_all(body: list[str], states: dict[str, object]) -> None:
    close_code(body, states)
    close_blocks(body, states)
    while close_component(body, states):
        pass


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
    raw_attrs = match.group(2)
    if name == "separator":
        body.append('<hr class="section-separator">')
        return True
    if name == "accordion":
        title = component_title(raw_attrs, "Details")
        body.append(f'<details class="accordion"><summary>{inline_markup(title)}</summary>')
        close_tag = "</details>"
    elif name in {"example-card", "block-template"}:
        title = component_title(raw_attrs, "")
        body.append(f'<section class="{name}"{component_attrs(raw_attrs)}>')
        if title:
            body.append(f'<header>{inline_markup(title)}</header>')
        close_tag = "</section>"
    else:
        body.append(f'<section class="{name}"{component_attrs(raw_attrs)}>')
        close_tag = "</section>"
    stack = states["components"]
    if isinstance(stack, list):
        stack.append(close_tag)
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
    fence = re.match(r"^```\s*([A-Za-z0-9_-]+)?", line)
    states["code"] = True
    states["code_lang"] = fence.group(1) if fence and fence.group(1) else ""
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
    classes = []
    display_title = inline_markup(title)
    if level == 2:
        if is_executive_summary(title):
            classes.append("no-chapter")
            states["chapter_count"] = int(states.get("chapter_count", 0))
            states["section_count"] = 0
        else:
            classes.append("chapter-heading")
            chapter_count = int(states.get("chapter_count", 0)) + 1
            states["chapter_count"] = chapter_count
            states["section_count"] = 0
            display_title = f'<span class="heading-number">{chapter_count}.</span> {inline_markup(title)}'
    elif level == 3 and int(states.get("chapter_count", 0)) > 0:
        classes.append("section-heading")
        section_count = int(states.get("section_count", 0)) + 1
        states["section_count"] = section_count
        display_title = (
            f'<span class="heading-number">{states["chapter_count"]}.{section_count}</span> {inline_markup(title)}'
        )
    class_attr = f' class="{" ".join(classes)}"' if classes else ""
    headings.append((level, title, anchor))
    body.append(f'<h{level}{class_attr} id="{anchor}">{display_title}</h{level}>')
    return True


def handle_comment(line: str, states: dict[str, object]) -> bool:
    stripped = line.strip()
    if states.get("comment"):
        if "-->" in stripped:
            states["comment"] = False
        return True
    if not stripped.startswith("<!--"):
        return False
    if "-->" not in stripped:
        states["comment"] = True
    return True


def handle_rule(line: str, body: list[str], states: dict[str, object]) -> bool:
    if not re.match(r"^(-{3,}|_{3,}|\*{3,})$", line.strip()):
        return False
    close_blocks(body, states)
    body.append('<hr class="section-separator">')
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
        body.append("<table><thead>")
        states["table"] = True
        body.append("<tr>{}</tr></thead><tbody>".format("".join(f"<th>{cell}</th>" for cell in cells)))
        return True
    body.append("<tr>{}</tr>".format("".join(f"<td>{cell}</td>" for cell in cells)))
    return True


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
    if handle_comment(line, states):
        return
    if handle_code_fence(line, body, states):
        return
    if handle_component(line, body, states):
        return
    if handle_rule(line, body, states):
        return
    if handle_heading(line, headings, body, states):
        return
    if handle_table(line, body, states):
        return
    if handle_list(line, body, states):
        return
    if handle_blockquote(line, body, states):
        return
    handle_paragraph(line, body, states)


def render_markdown(text: str) -> tuple[list[tuple[int, str, str]], str]:
    validate_markdown_badges(text)
    headings: list[tuple[int, str, str]] = []
    body: list[str] = []
    states: dict[str, object] = {
        "comment": False,
        "list": False,
        "list_tag": "",
        "table": False,
        "components": [],
        "code": False,
        "code_lang": "",
        "code_lines": [],
        "chapter_count": 0,
        "section_count": 0,
    }
    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        handle_markdown_line(line, headings, body, states) if line or states.get("code") else close_blocks(body, states)
    close_all(body, states)
    return headings, "\n".join(body)
