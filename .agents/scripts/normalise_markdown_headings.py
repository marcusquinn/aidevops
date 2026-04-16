#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
Heading detection and hierarchy helpers for normalise-markdown.py.

Extracted from normalise-markdown.py to reduce file complexity.
"""

import re
from typing import List, Optional, Tuple

# Compiled regex patterns
_RE_HEADING_PREFIX = re.compile(r'^#+')
_RE_SENTENCE_END = re.compile(r'[.!?]$')


def _detect_explicit_heading(stripped: str) -> Optional[Tuple[int, str]]:
    """Return (level, text) if line is already a markdown heading, else None."""
    if not stripped.startswith('#'):
        return None
    level = len(_RE_HEADING_PREFIX.match(stripped).group())
    text = stripped.lstrip('#').strip()
    return (level, text)


def _detect_all_caps_heading(
    stripped: str, has_blank_before: bool, has_blank_after: bool
) -> Optional[Tuple[int, str]]:
    """Return (level, text) for ALL CAPS short lines, else None."""
    if not (stripped.isupper() and len(stripped.split()) >= 1 and len(stripped) < 60):
        return None
    if has_blank_before:
        return (2, stripped.title())
    if has_blank_after:
        return (3, stripped.title())
    return None


def _detect_title_case_heading(
    stripped: str, has_blank_before: bool, has_blank_after: bool
) -> Optional[Tuple[int, str]]:
    """Return (level, text) for title-case short lines surrounded by blanks, else None."""
    is_title_case = stripped[0].isupper() and not stripped.endswith(('.', '!', '?', ':'))
    is_short = len(stripped) < 60
    if not (is_title_case and is_short and has_blank_before and has_blank_after):
        return None
    if _RE_SENTENCE_END.search(stripped):
        return None
    return (3, stripped)


def detect_heading_from_structure(
    line: str,
    prev_line: str,
    next_line: str,
    email_mode: bool = False,
) -> Tuple[int, str]:
    """
    Detect if a line should be a heading based on structural cues.
    Returns (heading_level, cleaned_text) or (0, line) if not a heading.
    In email mode, only explicit markdown headings (#) are detected —
    heuristic detection is skipped since email section detection already
    inserts proper headings for quoted replies, signatures, and forwards.
    """
    stripped = line.strip()

    explicit = _detect_explicit_heading(stripped)
    if explicit is not None:
        return explicit

    if not stripped or email_mode:
        return (0, line)

    has_blank_before = not prev_line.strip()
    has_blank_after = not next_line.strip()

    result = _detect_all_caps_heading(stripped, has_blank_before, has_blank_after)
    if result is not None:
        return result

    result = _detect_title_case_heading(stripped, has_blank_before, has_blank_after)
    if result is not None:
        return result

    return (0, line)


def _ensure_h1(level: int, has_h1: bool) -> Tuple[int, bool]:
    """Promote first heading to H1 if needed. Returns (adjusted_level, has_h1)."""
    if has_h1:
        return (level, True)
    return (1, True)


def _clamp_heading_level(level: int, heading_stack: List[int]) -> int:
    """Prevent skipping heading levels (e.g. H2 -> H4 becomes H2 -> H3)."""
    if heading_stack and level > heading_stack[-1] + 1:
        return heading_stack[-1] + 1
    return level


def _update_heading_stack(level: int, heading_stack: List[int]) -> None:
    """Pop stale levels and push the new level onto the stack (in-place)."""
    while heading_stack and heading_stack[-1] >= level:
        heading_stack.pop()
    heading_stack.append(level)


def normalise_heading_hierarchy(
    lines: List[str],
    email_mode: bool = False,
) -> List[str]:
    """
    Ensure heading hierarchy is valid:
    - Single # root heading
    - Sequential nesting (no skipped levels)
    """
    result = []
    heading_stack: List[int] = []
    has_h1 = False

    for i, line in enumerate(lines):
        prev_line = lines[i - 1] if i > 0 else ""
        next_line = lines[i + 1] if i < len(lines) - 1 else ""

        level, text = detect_heading_from_structure(
            line, prev_line, next_line, email_mode=email_mode
        )

        if level > 0:
            level, has_h1 = _ensure_h1(level, has_h1)
            level = _clamp_heading_level(level, heading_stack)
            _update_heading_stack(level, heading_stack)
            result.append('#' * level + ' ' + text)
        else:
            result.append(line)

    return result
