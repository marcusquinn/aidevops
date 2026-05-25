#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Markdown rendering helpers for report-render-helper.py."""

from __future__ import annotations

import re

from report_render_badges import badge_html
from report_render_blocks import close_blocks, flush_paragraph, handle_blockquote, handle_list, handle_table
from report_render_code import close_code, code_block_html, handle_code_fence
from report_render_components import close_component, handle_component
from report_render_diagrams import render_mermaid_svg
from report_render_enhance import action_prompt_from_text, action_section_pattern, action_summary_from_text, inject_action_prompts, inject_source_links, strip_html
from report_render_headings import handle_heading
from report_render_markup import inline_markup


def validate_markdown_badges(text: str) -> None:
    for match in re.finditer(r"\{\{\s*evidence\s*:\s*([^}]+?)\s*\}\}", text, re.I):
        badge_html(match.group(1))


ACTION_COMPONENT_CLASSES = ("action-line", "action-panel")
KEEP_WITH_HEADING_CLASSES = {
    "action-line", "action-panel", "accordion", "block-template", "callout", "checklist-card",
    "details-note", "evidence-panel", "example-card", "facts-table-wrap", "good-bad", "impact-panel",
    "info-panel", "latex-rendered-block", "mermaid-rendered", "myth-callout", "priority-group",
    "quote-card", "source-card", "source-item", "source-list", "sources-group", "sources-layout",
    "tactic-card", "code-block-wrap",
}


def _action_section_pattern() -> re.Pattern[str]:
    return action_section_pattern(ACTION_COMPONENT_CLASSES)


def extract_action_prompts(text: str) -> list[tuple[str, str]]:
    _, body = render_markdown(text, inject_prompts=False)
    prompts: list[tuple[str, str]] = []
    for match in _action_section_pattern().finditer(body):
        action_text = action_summary_from_text(strip_html(match.group(3)))
        if not action_text:
            continue
        prompts.append((action_text, action_prompt_from_text(action_text)))
    return prompts


def render_action_prompt_markdown(text: str) -> str:
    prompts = extract_action_prompts(text)
    if not prompts:
        return "# Action Prompts\n\nNo action prompts found.\n"
    lines = ["# Action Prompts", ""]
    for index, (action_text, prompt_text) in enumerate(prompts, start=1):
        lines.extend(
            [
                f"## {index}. {action_text}",
                "",
                "```text",
                prompt_text,
                "```",
                "",
            ]
        )
    return "\n".join(lines)

def close_all(body: list[str], states: dict[str, object]) -> None:
    close_code(body, states)
    close_blocks(body, states)
    while close_component(body, states):
        pass


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


def current_component(states: dict[str, object]) -> str:
    names = states.get("component_names")
    if isinstance(names, list) and names:
        return str(names[-1])
    return ""


def _is_heading_html(line: str, level: int | None = None) -> bool:
    if level is not None:
        return bool(re.match(rf"^<h{level}\b", line))
    return bool(re.match(r"^<h[23]\b", line))


def _element_classes(line: str) -> set[str]:
    match = re.match(r'^<[a-z0-9]+\b[^>]*\bclass="([^"]+)"', line.strip(), re.I)
    if not match:
        return set()
    return set(match.group(1).split())


def _is_keep_with_heading_target(line: str) -> bool:
    return bool(_element_classes(line) & KEEP_WITH_HEADING_CLASSES)


def _find_block_end(body: list[str], start_index: int) -> int:
    start = body[start_index].strip()
    match = re.match(r"^<(details|section)\b", start)
    if not match:
        return start_index
    tag = match.group(1)
    depth = 0
    for index in range(start_index, len(body)):
        line = body[index]
        depth += len(re.findall(rf"<{tag}\b", line))
        depth -= len(re.findall(rf"</{tag}>", line))
        if depth <= 0:
            return index
    return start_index


def wrap_keep_with_heading_blocks(body: list[str]) -> list[str]:
    wrapped: list[str] = []
    index = 0
    while index < len(body):
        if not _is_heading_html(body[index]):
            wrapped.append(body[index])
            index += 1
            continue
        target_index = index + 1
        if _is_heading_html(body[index], 2) and target_index < len(body) and _is_heading_html(body[target_index], 3):
            target_index += 1
        if target_index >= len(body) or not _is_keep_with_heading_target(body[target_index]):
            wrapped.append(body[index])
            index += 1
            continue
        end_index = _find_block_end(body, target_index)
        wrapper_classes = ["report-keep-with-heading"]
        if "chapter-heading" in _element_classes(body[index]):
            wrapper_classes.append("report-chapter-page")
        wrapped.append(f'<section class="{" ".join(wrapper_classes)}">')
        wrapped.extend(body[index : end_index + 1])
        wrapped.append("</section>")
        index = end_index + 1
    return wrapped


def handle_bar_chart_line(line: str, body: list[str], states: dict[str, object]) -> bool:
    if current_component(states) != "bar-chart":
        return False
    flush_paragraph(body, states)
    match = re.search(r"(\d{1,3})\s*%", line)
    value = max(0, min(100, int(match.group(1)))) if match else 72
    body.append(f'<p style="--bar-value: {value}%">{inline_markup(line)}</p>')
    return True


def handle_paragraph(line: str, body: list[str], states: dict[str, object]) -> None:
    if states.get("list") or states.get("table"):
        close_blocks(body, states)
    if handle_bar_chart_line(line, body, states):
        return
    if line.lower().startswith(("source:", "source card:")):
        flush_paragraph(body, states)
        body.append(
            f'<aside class="source-card">{inline_markup(line)}'
            '<a class="source-card-link" href="#sources" aria-label="Jump to sources"></a></aside>'
        )
        return
    paragraph_lines = states.get("paragraph")
    if isinstance(paragraph_lines, list):
        paragraph_lines.append(line)


def handle_markdown_line(
    line: str,
    headings: list[tuple[int, str, str]],
    body: list[str],
    states: dict[str, object],
) -> None:
    handlers = (
        lambda: handle_comment(line, states),
        lambda: handle_code_fence(line, body, states, close_blocks),
        lambda: handle_component(line, body, states, close_blocks),
        lambda: handle_rule(line, body, states),
        lambda: handle_heading(line, headings, body, states, close_blocks),
        lambda: handle_table(line, body, states),
        lambda: handle_list(line, body, states),
        lambda: handle_blockquote(line, body, states),
    )
    handled = False
    for handler in handlers:
        if handler():
            handled = True
            break
    if not handled:
        handle_paragraph(line, body, states)


def render_markdown(text: str, inject_prompts: bool = True) -> tuple[list[tuple[int, str, str]], str]:
    validate_markdown_badges(text)
    headings: list[tuple[int, str, str]] = []
    body: list[str] = []
    states: dict[str, object] = {
        "comment": False,
        "list": False,
        "list_tag": "",
        "table": False,
        "components": [],
        "component_names": [],
        "code": False,
        "code_lang": "",
        "code_lines": [],
        "chapter_count": 0,
        "section_count": 0,
        "paragraph": [],
    }
    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        handle_markdown_line(line, headings, body, states) if line or states.get("code") else close_blocks(body, states)
    close_all(body, states)
    body = wrap_keep_with_heading_blocks(body)
    body_html = "\n".join(body)
    body_html = inject_source_links(body_html)
    if inject_prompts:
        body_html = inject_action_prompts(body_html, ACTION_COMPONENT_CLASSES, code_block_html)
    return headings, body_html
