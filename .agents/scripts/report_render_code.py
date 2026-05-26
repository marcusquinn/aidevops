#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Code block rendering helpers for report Markdown."""

from __future__ import annotations

import html
import re
from collections.abc import Callable

from report_render_diagrams import render_latex_block, render_mermaid_svg


def code_block_html(code_text: str, lang: str = "text", title: str = "Code") -> str:
    safe_lang = html.escape(lang or "text")
    safe_title = html.escape(title)
    pre_class = f"language-{safe_lang}"
    if lang == "mermaid":
        pre_class = "mermaid"
    elif lang == "latex-block":
        pre_class = "latex-block"
    return (
        '<div class="code-block-wrap">'
        f'<div class="code-block-head"><span>{safe_title}</span>'
        '<button class="code-copy" type="button" aria-label="Copy code" title="Copy code">⧉</button></div>'
        f'<pre class="{pre_class}"><code>{html.escape(code_text)}</code></pre></div>'
    )


def close_code(body: list[str], states: dict[str, object]) -> None:
    if not states.get("code"):
        return
    lines = states.get("code_lines", [])
    code_text = "\n".join(lines) if isinstance(lines, list) else ""
    lang = str(states.get("code_lang", "")).strip().lower()
    if lang == "mermaid":
        body.append(code_block_html(code_text, "mermaid", "Mermaid source fallback"))
        rendered = render_mermaid_svg(code_text)
        if rendered:
            body.append(rendered)
    elif lang in {"latex", "tex"}:
        body.append(code_block_html(code_text, "latex-block", "LaTeX source fallback"))
        rendered = render_latex_block(code_text)
        if rendered:
            body.append(rendered)
    else:
        body.append(code_block_html(code_text, lang or "text", f"{(lang or 'text').title()} code"))
    states["code"] = False
    states["code_lines"] = []
    states["code_lang"] = ""


def handle_code_fence(
    line: str,
    body: list[str],
    states: dict[str, object],
    close_blocks: Callable[[list[str], dict[str, object]], None],
) -> bool:
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
