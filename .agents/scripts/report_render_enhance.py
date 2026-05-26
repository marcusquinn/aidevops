#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Post-processing helpers for report Markdown rendering."""

from __future__ import annotations

import html
import re
from collections.abc import Callable


def strip_html(value: str) -> str:
    text = re.sub(r"<[^>]+>", " ", value)
    return " ".join(html.unescape(text).split())


def action_prompt_from_text(action_text: str) -> str:
    cleaned = re.sub(r"^(?:action|next action):\s*", "", action_text.strip(), flags=re.I)
    if not cleaned:
        cleaned = action_text.strip()
    return (
        f"Reference this report action: {cleaned}\n\n"
        "Guide me through the tools, resources, accounts, permissions, source material, and access needed to take "
        "this action. Break the work into numbered steps, call out any missing inputs before execution, include "
        "safe handling for credentials or confidential data, and finish with verification evidence I can capture."
    )


def action_summary_from_text(section_text: str) -> str:
    text = " ".join(section_text.split())
    match = re.search(
        r"\b(Action|Next action):\s*(.*?)(?=\s+(?:Why|What|How|Verify|Owner|Proof):|$)",
        text,
        flags=re.I,
    )
    if not match:
        return text
    label = "Next action" if match.group(1).lower().startswith("next") else "Action"
    return f"{label}: {match.group(2).strip()}"


def action_prompt_details(prompt_text: str, code_renderer: Callable[[str, str, str], str]) -> str:
    return (
        '<details class="accordion action-prompt" open><summary>Action Prompt</summary>'
        f'{code_renderer(prompt_text, "text", "Copyable action prompt")}'
        '</details>'
    )


def action_section_pattern(classes: tuple[str, ...]) -> re.Pattern[str]:
    class_pattern = "|".join(re.escape(name) for name in classes)
    return re.compile(rf'(<section class="({class_pattern})"[^>]*>)(.*?)(</section>)', re.S)


def inject_action_prompts(body_html: str, classes: tuple[str, ...], code_renderer: Callable[[str, str, str], str]) -> str:
    def replace(match: re.Match[str]) -> str:
        section_body = match.group(3)
        if 'class="accordion action-prompt"' in section_body:
            return match.group(0)
        action_text = action_summary_from_text(strip_html(section_body))
        if not action_text:
            return match.group(0)
        prompt = action_prompt_details(action_prompt_from_text(action_text), code_renderer)
        return f"{match.group(1)}{section_body}{prompt}{match.group(4)}"

    return action_section_pattern(classes).sub(replace, body_html)


def inject_source_links(body_html: str) -> str:
    def replace(match: re.Match[str]) -> str:
        source_body = match.group(2)
        if 'class="source-card-link"' in source_body:
            return match.group(0)
        link = '<a class="source-card-link" href="#sources" aria-label="Jump to sources"></a>'
        return f"{match.group(1)}{source_body}{link}{match.group(3)}"

    return re.sub(r'(<section class="(?:source-card|source-item)"[^>]*>)(.*?)(</section>)', replace, body_html, flags=re.S)
