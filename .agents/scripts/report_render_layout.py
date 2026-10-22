# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Keep rendered report headings with their following HTML component blocks."""

from __future__ import annotations

import re


KEEP_WITH_HEADING_CLASSES = {
    "action-line", "action-panel", "accordion", "block-template", "callout", "checklist-card",
    "details-note", "evidence-panel", "example-card", "facts-table-wrap", "good-bad", "impact-panel",
    "info-panel", "latex-rendered-block", "mermaid-rendered", "myth-callout", "priority-group",
    "quote-card", "source-card", "source-item", "source-list", "sources-group", "sources-layout",
    "tactic-card", "code-block-wrap",
}


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
