#!/usr/bin/env python3
"""
normalise-markdown.py - Fix markdown heading hierarchy and structure.

Part of aidevops document-creation-helper.sh (extracted for complexity reduction).

Usage: normalise-markdown.py <input_file> <output_file> [email_mode]
  email_mode: 'true' or 'false' (default: false)
"""

import sys
import re
from typing import List, Tuple


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

    # Already a markdown heading
    if stripped.startswith('#'):
        level = len(re.match(r'^#+', stripped).group())
        text = stripped.lstrip('#').strip()
        return (level, text)

    # Empty line
    if not stripped:
        return (0, line)

    # In email mode, skip heuristic heading detection — email section
    # detection (quoted replies, signatures, forwards) already adds headings
    if email_mode:
        return (0, line)

    # Detect heading patterns:
    # 1. ALL CAPS lines (likely headings)
    # 2. Title Case with blank lines before/after
    # 3. Short lines (<60 chars) that are capitalized with blank lines around them

    is_all_caps = stripped.isupper() and len(stripped.split()) >= 1
    is_title_case = stripped[0].isupper() and not stripped.endswith(('.', '!', '?', ':'))
    is_short = len(stripped) < 60
    has_blank_before = not prev_line.strip()
    has_blank_after = not next_line.strip()

    # ALL CAPS = likely heading (level 2 if has blank before, else level 3)
    if is_all_caps and is_short:
        if has_blank_before:
            return (2, stripped.title())
        # Even without blank before, if it's ALL CAPS and short, likely a heading
        elif has_blank_after:
            return (3, stripped.title())

    # Title case, short, surrounded by blanks = likely heading level 3
    if is_title_case and is_short and has_blank_before and has_blank_after:
        # Check if it looks like a sentence (ends with punctuation)
        if not re.search(r'[.!?]$', stripped):
            return (3, stripped)

    return (0, line)


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
    heading_stack = []
    has_h1 = False

    for i, line in enumerate(lines):
        prev_line = lines[i - 1] if i > 0 else ""
        next_line = lines[i + 1] if i < len(lines) - 1 else ""

        level, text = detect_heading_from_structure(
            line, prev_line, next_line, email_mode=email_mode
        )

        if level > 0:
            # Ensure we have an H1
            if not has_h1:
                if level == 1:
                    has_h1 = True
                else:
                    # Promote first heading to H1
                    level = 1
                    has_h1 = True

            # Ensure sequential nesting
            if heading_stack:
                last_level = heading_stack[-1]
                # Can't skip levels (e.g., H2 -> H4)
                if level > last_level + 1:
                    level = last_level + 1

            # Update stack
            while heading_stack and heading_stack[-1] >= level:
                heading_stack.pop()
            heading_stack.append(level)

            result.append('#' * level + ' ' + text)
        else:
            result.append(line)

    return result


def align_table_pipes(lines: List[str]) -> List[str]:
    """Align markdown table pipes for readability."""
    result = []
    in_table = False
    table_lines = []

    for line in lines:
        stripped = line.strip()

        # Detect table rows (contain |)
        if '|' in stripped and stripped.count('|') >= 2:
            in_table = True
            table_lines.append(line)
        else:
            # End of table
            if in_table and table_lines:
                # Process and align the table
                result.extend(align_table(table_lines))
                table_lines = []
                in_table = False
            result.append(line)

    # Handle table at end of file
    if table_lines:
        result.extend(align_table(table_lines))

    return result


def align_table(table_lines: List[str]) -> List[str]:
    """Align a single table's pipes."""
    if not table_lines:
        return []

    # Parse table cells
    rows = []
    for line in table_lines:
        # Split by | and strip whitespace
        cells = [cell.strip() for cell in line.split('|')]
        # Remove empty first/last cells (from leading/trailing |)
        if cells and not cells[0]:
            cells = cells[1:]
        if cells and not cells[-1]:
            cells = cells[:-1]
        rows.append(cells)

    if not rows:
        return table_lines

    # Find max width for each column
    num_cols = max(len(row) for row in rows)
    col_widths = [0] * num_cols

    for row in rows:
        for i, cell in enumerate(row):
            if i < num_cols:
                col_widths[i] = max(col_widths[i], len(cell))

    # Rebuild table with aligned pipes
    result = []
    for row in rows:
        # Pad cells to column width
        padded = []
        for i in range(num_cols):
            cell = row[i] if i < len(row) else ''
            # Check if this is a separator row (contains only -, :, and spaces)
            if re.match(r'^[\s:-]+$', cell):
                # Preserve alignment markers
                if cell.startswith(':') and cell.endswith(':'):
                    padded.append(':' + '-' * (col_widths[i] - 2) + ':')
                elif cell.startswith(':'):
                    padded.append(':' + '-' * (col_widths[i] - 1))
                elif cell.endswith(':'):
                    padded.append('-' * (col_widths[i] - 1) + ':')
                else:
                    padded.append('-' * col_widths[i])
            else:
                padded.append(cell.ljust(col_widths[i]))

        result.append('| ' + ' | '.join(padded) + ' |')

    return result


def detect_email_sections(lines: List[str]) -> List[str]:
    """
    Detect and structure email-specific sections:
    - Quoted replies (lines starting with >)
    - Signature blocks (lines after --)
    - Forwarded message headers (---------- Forwarded message ----------)
    """
    result = []
    in_quote_block = False
    in_signature = False
    in_forwarded = False

    for i, line in enumerate(lines):
        stripped = line.strip()

        # Detect forwarded message headers
        if re.match(r'^-{3,}\s*(Forwarded|Original)\s+(message|Message)\s*-{3,}$', stripped):
            # Close any open quote block
            if in_quote_block:
                result.append('')
                in_quote_block = False
            if in_signature:
                in_signature = False
            in_forwarded = True
            result.append('')
            result.append('## Forwarded Message')
            result.append('')
            continue

        # Detect "Begin forwarded message:" variant
        if re.match(r'^Begin forwarded message\s*:', stripped, re.IGNORECASE):
            if in_quote_block:
                result.append('')
                in_quote_block = False
            in_forwarded = True
            result.append('')
            result.append('## Forwarded Message')
            result.append('')
            continue

        # Detect forwarded header fields (From:, Date:, Subject:, To:)
        if in_forwarded and re.match(
            r'^(From|Date|Subject|To|Cc|Sent|Reply-To)\s*:', stripped
        ):
            result.append(f'**{stripped}**')
            continue

        # End forwarded header block on first non-header, non-blank line
        if in_forwarded and stripped and not re.match(
            r'^(From|Date|Subject|To|Cc|Sent|Reply-To)\s*:', stripped
        ):
            in_forwarded = False
            result.append('')

        # Detect signature block: line is exactly "-- " or "--"
        if stripped in ('--', '-- '):
            if in_quote_block:
                result.append('')
                in_quote_block = False
            in_signature = True
            result.append('')
            result.append('## Signature')
            result.append('')
            continue

        # Lines in signature block
        if in_signature:
            # End signature if we hit a quoted reply or forwarded message
            if stripped.startswith('>') or re.match(
                r'^-{3,}\s*(Forwarded|Original)', stripped
            ):
                in_signature = False
                # Re-process this line
            else:
                result.append(line)
                continue

        # Detect quoted reply lines (starting with >)
        if stripped.startswith('>'):
            # Start a new quote section if transitioning from non-quoted
            if not in_quote_block:
                in_quote_block = True
                # Check if previous line has "On ... wrote:" pattern
                prev_wrote = False
                if i > 0:
                    prev = lines[i - 1].strip()
                    if re.match(r'^On\s+.+wrote\s*:\s*$', prev):
                        prev_wrote = True
                    elif re.match(r'^On\s+.+wrote\s*:\s*$', prev.rstrip('>').strip()):
                        prev_wrote = True
                if not prev_wrote:
                    result.append('')
                    result.append('## Quoted Reply')
                    result.append('')

            # Preserve the quoted line as-is (blockquote syntax)
            result.append(line)
            continue

        # Transition out of quote block
        if in_quote_block and not stripped.startswith('>'):
            in_quote_block = False
            # Check if this line is "On ... wrote:" (attribution for next quote)
            if re.match(r'^On\s+.+wrote\s*:\s*$', stripped):
                result.append('')
                result.append('## Quoted Reply')
                result.append('')
                result.append(f'*{stripped}*')
                continue

        # Regular line
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

    # Step 0 (email only): Detect and structure email-specific sections
    if email_mode:
        lines = detect_email_sections(lines)

    # Step 1: Normalise heading hierarchy
    lines = normalise_heading_hierarchy(lines, email_mode=email_mode)

    # Step 2: Align table pipes
    lines = align_table_pipes(lines)

    # Write output
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))
        # Ensure file ends with newline
        if lines and lines[-1]:
            f.write('\n')


if __name__ == '__main__':
    main()
