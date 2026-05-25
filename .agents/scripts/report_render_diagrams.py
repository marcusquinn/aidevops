#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Self-contained diagram renderers for report Markdown examples."""

from __future__ import annotations

import html
import re


def mermaid_node_parts(raw_node: str) -> tuple[str, str]:
    match = re.match(r"^([A-Za-z0-9_-]+)\s*(?:\[([^\]]+)\])?$", raw_node.strip())
    if not match:
        fallback = raw_node.strip()
        return fallback, fallback
    node_id = match.group(1)
    label = (match.group(2) or node_id).strip()
    return node_id, label


def mermaid_graph(code_text: str) -> tuple[dict[str, str], list[tuple[str, str]]]:
    nodes: dict[str, str] = {}
    edges: list[tuple[str, str]] = []
    for line in code_text.splitlines():
        if "-->" not in line:
            continue
        left, right = [part.strip() for part in line.split("-->", 1)]
        left_id, left_label = mermaid_node_parts(left)
        right_id, right_label = mermaid_node_parts(right)
        if left_id and left_id not in nodes:
            nodes[left_id] = left_label
        if right_id and right_id not in nodes:
            nodes[right_id] = right_label
        if left_id and right_id:
            edges.append((left_id, right_id))
    return nodes, edges


def mermaid_layout(node_count: int) -> dict[str, int]:
    if node_count > 4:
        columns = min(3, node_count)
        rows = (node_count + columns - 1) // columns
        cell_width = 220
        cell_height = 115
        width = max(720, columns * cell_width + 48)
        height = rows * cell_height + 50
    else:
        columns = node_count
        cell_width = max(185, 720 // max(columns, 1))
        cell_height = 95
        width = max(720, node_count * 190)
        height = 130
    return {"columns": columns, "cell_width": cell_width, "cell_height": cell_height, "width": width, "height": height}


def mermaid_edge_arrow(left_position: tuple[int, int, int, int], right_position: tuple[int, int, int, int]) -> str:
    left_x, left_y, left_column, left_row = left_position
    right_x, right_y, right_column, right_row = right_position
    if left_row == right_row and left_column < right_column:
        return f'<line x1="{left_x + 165}" y1="{left_y + 29}" x2="{right_x - 10}" y2="{right_y + 29}" class="diagram-arrow" />'
    if left_column == right_column and left_row < right_row:
        return f'<line x1="{left_x + 80}" y1="{left_y + 63}" x2="{right_x + 80}" y2="{right_y - 10}" class="diagram-arrow" />'
    mid_y = left_y + 78
    return f'<path d="M {left_x + 80} {left_y + 63} V {mid_y} H {right_x + 80} V {right_y - 10}" class="diagram-arrow" fill="none" />'


def mermaid_sequential_arrow(index: int, node_ids: list[str], positions: dict[str, tuple[int, int, int, int]], layout: dict[str, int]) -> str:
    node_id = node_ids[index]
    next_id = node_ids[index + 1]
    x, y, _, _ = positions[node_id]
    next_x, next_y, _, _ = positions[next_id]
    if (index + 1) % layout["columns"] == 0:
        return f'<path d="M {x + 80} {y + 63} V {next_y - 16} H {next_x + 80} V {next_y - 10}" class="diagram-arrow" fill="none" />'
    return f'<line x1="{x + 165}" y1="{y + 29}" x2="{next_x - 10}" y2="{next_y + 29}" class="diagram-arrow" />'


def render_mermaid_svg(code_text: str) -> str:
    """Render a small self-contained SVG for simple Mermaid flowchart examples."""

    nodes, edges = mermaid_graph(code_text)
    if len(nodes) < 2:
        return ""
    layout = mermaid_layout(len(nodes))
    boxes = []
    positions: dict[str, tuple[int, int, int, int]] = {}
    arrows = []
    for index, (node_id, label) in enumerate(nodes.items()):
        column = index % layout["columns"]
        row = index // layout["columns"]
        x = 24 + column * layout["cell_width"]
        y = 35 + row * layout["cell_height"]
        positions[node_id] = (x, y, column, row)
        safe_label = html.escape(label)
        boxes.append(
            f'<rect x="{x}" y="{y}" width="160" height="58" rx="14" class="diagram-node" />'
            f'<text x="{x + 80}" y="{y + 35}" text-anchor="middle" class="diagram-label">{safe_label}</text>'
        )
    for left_id, right_id in edges:
        if left_id in positions and right_id in positions:
            arrows.append(mermaid_edge_arrow(positions[left_id], positions[right_id]))
    if not arrows:
        node_ids = list(nodes.keys())
        for index in range(len(node_ids) - 1):
            arrows.append(mermaid_sequential_arrow(index, node_ids, positions, layout))
    return (
        '<figure class="mermaid-rendered" aria-label="Rendered Mermaid diagram">'
        f'<svg viewBox="0 0 {layout["width"]} {layout["height"]}" role="img" xmlns="http://www.w3.org/2000/svg">'
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
    display_formula = formula
    replacements = {
        r"\alpha": "α",
        r"\beta": "β",
        r"\gamma": "γ",
        r"\delta": "δ",
        r"\times": "×",
        r"\cdot": "·",
    }
    for source, replacement in replacements.items():
        display_formula = display_formula.replace(source, replacement)
    display_formula = re.sub(r"\text\{([^}]+)\}", r"\1", display_formula)
    display_formula = re.sub(r"\s*([=+\-])\s*", r" \1 ", display_formula)
    display_formula = " ".join(display_formula.split())
    return (
        '<figure class="latex-rendered-block" aria-label="Rendered LaTeX formula">'
        f'<div role="math" aria-label="{html.escape(formula)}">{html.escape(display_formula)}</div>'
        '<figcaption>Rendered LaTeX example, embedded as self-contained HTML.</figcaption>'
        '</figure>'
    )
