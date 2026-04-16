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
from typing import List

from normalise_markdown_headings import normalise_heading_hierarchy
from normalise_markdown_email import detect_email_sections

# Compiled regex patterns (table-specific)
_RE_SEPARATOR_CELL = re.compile(r'^[\s:-]+$')


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
