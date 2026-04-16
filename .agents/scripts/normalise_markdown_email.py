#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
Email section detection helpers for normalise-markdown.py.

Extracted from normalise-markdown.py to reduce file complexity.
Detects quoted replies, signature blocks, and forwarded message headers.
"""

import re
from typing import List

# Compiled regex patterns
_RE_FORWARDED_HEADER = re.compile(
    r'^-{3,}\s*(Forwarded|Original)\s+(message|Message)\s*-{3,}$'
)
_RE_BEGIN_FORWARDED = re.compile(r'^Begin forwarded message\s*:', re.IGNORECASE)
_RE_FORWARDED_FIELDS = re.compile(
    r'^(From|Date|Subject|To|Cc|Sent|Reply-To)\s*:'
)
_RE_ON_WROTE = re.compile(r'^On\s+.+wrote\s*:\s*$')
_RE_SIGNATURE_MARKER = re.compile(r'^--\s*$')


class _EmailState:
    """Mutable state bag for detect_email_sections iteration."""

    __slots__ = ('in_quote_block', 'in_signature', 'in_forwarded', 'lines', 'index')

    def __init__(self, lines: List[str]) -> None:
        self.in_quote_block: bool = False
        self.in_signature: bool = False
        self.in_forwarded: bool = False
        self.lines: List[str] = lines
        self.index: int = 0


def _is_forwarded_header_line(stripped: str) -> bool:
    """Return True if the line is a forwarded/original message separator."""
    return bool(_RE_FORWARDED_HEADER.match(stripped))


def _is_begin_forwarded_line(stripped: str) -> bool:
    """Return True if the line is a 'Begin forwarded message:' variant."""
    return bool(_RE_BEGIN_FORWARDED.match(stripped))


def _is_forwarded_field(stripped: str) -> bool:
    """Return True if the line is a forwarded header field (From:, Date:, …)."""
    return bool(_RE_FORWARDED_FIELDS.match(stripped))


def _is_signature_marker(stripped: str) -> bool:
    """Return True if the line is the email signature separator '-- '."""
    return stripped in ('--', '-- ') or bool(_RE_SIGNATURE_MARKER.match(stripped))


def _prev_line_has_wrote(state: _EmailState) -> bool:
    """Return True if the line before current index matches 'On … wrote:' pattern."""
    if state.index <= 0:
        return False
    prev = state.lines[state.index - 1].strip()
    return bool(_RE_ON_WROTE.match(prev)) or bool(
        _RE_ON_WROTE.match(prev.rstrip('>').strip())
    )


def _handle_forwarded_header(
    line: str, stripped: str, state: _EmailState, result: List[str]
) -> bool:
    """Handle forwarded message separator lines. Returns True if consumed."""
    if not (_is_forwarded_header_line(stripped) or _is_begin_forwarded_line(stripped)):
        return False
    if state.in_quote_block:
        result.append('')
        state.in_quote_block = False
    state.in_signature = False
    state.in_forwarded = True
    result.extend(['', '## Forwarded Message', ''])
    return True


def _handle_forwarded_field(
    line: str, stripped: str, state: _EmailState, result: List[str]
) -> bool:
    """Handle header fields inside a forwarded block. Returns True if consumed."""
    if not state.in_forwarded:
        return False
    if _is_forwarded_field(stripped):
        result.append(f'**{stripped}**')
        return True
    if stripped:
        state.in_forwarded = False
        result.append('')
    return False


def _handle_signature_marker(
    line: str, stripped: str, state: _EmailState, result: List[str]
) -> bool:
    """Handle the '-- ' signature separator. Returns True if consumed."""
    if not _is_signature_marker(stripped):
        return False
    if state.in_quote_block:
        result.append('')
        state.in_quote_block = False
    state.in_signature = True
    result.extend(['', '## Signature', ''])
    return True


def _handle_signature_body(
    line: str, stripped: str, state: _EmailState, result: List[str]
) -> bool:
    """Handle lines inside a signature block. Returns True if consumed."""
    if not state.in_signature:
        return False
    if stripped.startswith('>') or _is_forwarded_header_line(stripped):
        state.in_signature = False
        return False
    result.append(line)
    return True


def _handle_quote_start(
    line: str, stripped: str, state: _EmailState, result: List[str]
) -> bool:
    """Handle quoted reply lines. Returns True if consumed."""
    if not stripped.startswith('>'):
        return False
    if not state.in_quote_block:
        state.in_quote_block = True
        if not _prev_line_has_wrote(state):
            result.extend(['', '## Quoted Reply', ''])
    result.append(line)
    return True


def _handle_quote_end(
    line: str, stripped: str, state: _EmailState, result: List[str]
) -> bool:
    """Handle transition out of a quote block. Returns True if consumed."""
    if not state.in_quote_block:
        return False
    state.in_quote_block = False
    if _RE_ON_WROTE.match(stripped):
        result.extend(['', '## Quoted Reply', '', f'*{stripped}*'])
        return True
    return False


# Registry of email section handlers — tried in order, first match wins.
_EMAIL_HANDLERS = [
    _handle_forwarded_header,
    _handle_forwarded_field,
    _handle_signature_marker,
    _handle_signature_body,
    _handle_quote_start,
    _handle_quote_end,
]


def detect_email_sections(lines: List[str]) -> List[str]:
    """
    Detect and structure email-specific sections:
    - Quoted replies (lines starting with >)
    - Signature blocks (lines after --)
    - Forwarded message headers (---------- Forwarded message ----------)
    """
    result: List[str] = []
    state = _EmailState(lines)

    for i, line in enumerate(lines):
        state.index = i
        stripped = line.strip()
        if not any(h(line, stripped, state, result) for h in _EMAIL_HANDLERS):
            result.append(line)

    return result
