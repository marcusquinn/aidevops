#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Self-contained diagram renderers for report Markdown examples."""

from __future__ import annotations

import html
import re


def mermaid_nodes(code_text: str) -> list[str]:
    nodes: list[str] = []
    for line in code_text.splitlines():
        if "-->" not in line:
            continue
        left, right = [part.strip() for part in line.split("-->", 1)]
        for node in (left, right):
            label = re.sub(r"^[A-Za-z0-9_]+\[([^\]]+)\]$", r"\1", node).strip()
            if label and label not in nodes:
                nodes.append(label)
    return nodes


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


def mermaid_arrow(index: int, layout: dict[str, int], x: int, y: int) -> str:
    columns = layout["columns"]
    cell_width = layout["cell_width"]
    if (index + 1) % columns == 0:
        next_row = index // columns + 1
        next_y = 35 + next_row * layout["cell_height"]
        return f'<path d="M {x + 80} {y + 63} V {next_y - 16} H 104 V {next_y + 28}" class="diagram-arrow" fill="none" />'
    return f'<line x1="{x + 165}" y1="{y + 29}" x2="{x + cell_width - 16}" y2="{y + 29}" class="diagram-arrow" />'


def render_mermaid_svg(code_text: str) -> str:
    """Render a small self-contained SVG for simple Mermaid flowchart examples."""

    nodes = mermaid_nodes(code_text)
    if len(nodes) < 2:
        return ""
    layout = mermaid_layout(len(nodes))
    boxes = []
    arrows = []
    for index, label in enumerate(nodes):
        column = index % layout["columns"]
        row = index // layout["columns"]
        x = 24 + column * layout["cell_width"]
        y = 35 + row * layout["cell_height"]
        safe_label = html.escape(label)
        boxes.append(
            f'<rect x="{x}" y="{y}" width="160" height="58" rx="14" class="diagram-node" />'
            f'<text x="{x + 80}" y="{y + 35}" text-anchor="middle" class="diagram-label">{safe_label}</text>'
        )
        if index < len(nodes) - 1:
            arrows.append(mermaid_arrow(index, layout, x, y))
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
