#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
normalise-markdown.py - Fix markdown heading hierarchy and structure.

Part of aidevops document-creation-helper.sh (extracted for complexity reduction).

Usage: normalise-markdown.py <input_file> <output_file> [email_mode]
  email_mode: 'true' or 'false' (default: false)
"""

import sys
import re
from typing import List, Optional, Tuple

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
_RE_SEPARATOR_CELL = re.compile(r'^[\s:-]+$')
_RE_HEADING_PREFIX = re.compile(r'^#+')
_RE_SENTENCE_END = re.compile(r'[.!?]$')


# ---------------------------------------------------------------------------
# Heading detection helpers
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Heading hierarchy helpers
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Table alignment helpers
# ---------------------------------------------------------------------------

def _parse_table_rows(table_lines: List[str]) -> List[List[str]]:
    """Parse table lines into a list of cell lists."""
    rows = []
    for line in table_lines:
        cells = [cell.strip() for cell in line.split('|')]
        if cells and not cells[0]:
            cells = cells[1:]
        if cells and not cells[-1]:
            cells = cells[:-1]
        rows.append(cells)
    return rows


def _compute_col_widths(rows: List[List[str]], num_cols: int) -> List[int]:
    """Return the max cell width for each column."""
    col_widths = [0] * num_cols
    for row in rows:
        for i, cell in enumerate(row):
            if i < num_cols:
                col_widths[i] = max(col_widths[i], len(cell))
    return col_widths


def _format_separator_cell(cell: str, width: int) -> str:
    """Format a separator cell (---) preserving alignment markers."""
    if cell.startswith(':') and cell.endswith(':'):
        return ':' + '-' * (width - 2) + ':'
    if cell.startswith(':'):
        return ':' + '-' * (width - 1)
    if cell.endswith(':'):
        return '-' * (width - 1) + ':'
    return '-' * width


def _format_table_row(
    row: List[str], col_widths: List[int], num_cols: int
) -> str:
    """Format a single table row with aligned pipes."""
    padded = []
    for i in range(num_cols):
        cell = row[i] if i < len(row) else ''
        if _RE_SEPARATOR_CELL.match(cell):
            padded.append(_format_separator_cell(cell, col_widths[i]))
        else:
            padded.append(cell.ljust(col_widths[i]))
    return '| ' + ' | '.join(padded) + ' |'


def align_table(table_lines: List[str]) -> List[str]:
    """Align a single table's pipes."""
    if not table_lines:
        return []

    rows = _parse_table_rows(table_lines)
    if not rows:
        return table_lines

    num_cols = max(len(row) for row in rows)
    col_widths = _compute_col_widths(rows, num_cols)

    return [_format_table_row(row, col_widths, num_cols) for row in rows]


def align_table_pipes(lines: List[str]) -> List[str]:
    """Align markdown table pipes for readability."""
    result = []
    in_table = False
    table_lines: List[str] = []

    for line in lines:
        stripped = line.strip()

        if '|' in stripped and stripped.count('|') >= 2:
            in_table = True
            table_lines.append(line)
        else:
            if in_table and table_lines:
                result.extend(align_table(table_lines))
                table_lines = []
                in_table = False
            result.append(line)

    if table_lines:
        result.extend(align_table(table_lines))

    return result


# ---------------------------------------------------------------------------
# Email section detection — decomposed into single-responsibility handlers
# ---------------------------------------------------------------------------

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


def main() -> None:
    if len(sys.argv) < 3:
        print(
            "Usage: normalise-markdown.py <input_file> <output_file> [email_mode]",
            file=sys.stderr,
        )
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = sys.argv[2]
    email_mode = sys.argv[3].lower() == 'true' if len(sys.argv) > 3 else False

    with open(input_file, 'r', encoding='utf-8') as f:
        lines = f.read().splitlines()

    if email_mode:
        lines = detect_email_sections(lines)

    lines = normalise_heading_hierarchy(lines, email_mode=email_mode)
    lines = align_table_pipes(lines)

    with open(output_file, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))
        if lines and lines[-1]:
            f.write('\n')


if __name__ == '__main__':
    main()
