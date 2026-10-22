# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email_normaliser_sections.py - Email section normalisation and thread reconstruction.

Extracted from email_normaliser.py to reduce file-level complexity.
Provides detection and structuring of email-specific sections (quoted
replies, signatures, forwarded messages) and thread reconstruction from
In-Reply-To/Message-ID headers.
"""

import re

# Explicit re-exports preserve the existing import surface.
from email_normaliser_threads import (
    parse_eml as parse_eml,
    parse_msg as parse_msg,
    extract_header_safe as extract_header_safe,
    parse_date_safe as parse_date_safe,
    _parse_email_thread_headers as _parse_email_thread_headers,
    build_thread_map as build_thread_map,
    _next_ancestor as _next_ancestor,
    _walk_ancestor_chain as _walk_ancestor_chain,
    _count_descendants as _count_descendants,
    reconstruct_thread as reconstruct_thread,
    _group_emails_by_thread as _group_emails_by_thread,
    _write_thread_index_files as _write_thread_index_files,
    generate_thread_index as generate_thread_index,
)


# ---------------------------------------------------------------------------
# Section normalisation
# ---------------------------------------------------------------------------

def _is_forwarded_header(stripped):
    """Check if a line is a forwarded message header delimiter."""
    if re.match(r'^-{3,}\s*(Forwarded|Original)\s+(message|Message)\s*-{3,}$', stripped):
        return True
    if re.match(r'^Begin forwarded message\s*:', stripped, re.IGNORECASE):
        return True
    return False


_HEADER_FIELD_RE = re.compile(
    r'^(From|Date|Subject|To|Cc|Sent|Reply-To)\s*:')

_ATTRIBUTION_RE = re.compile(r'^On\s+.+wrote\s*:\s*$')


def _is_signature_delimiter(stripped):
    """Check if a line is an email signature delimiter.

    A line that strips to '--' covers both the RFC 3676 delimiter ('-- ')
    and the common bare '--'.
    """
    return stripped == '--'


def _has_attribution_before(lines, index):
    """Check if the previous line has an 'On ... wrote:' attribution pattern."""
    if index <= 0:
        return False
    prev = re.sub(r'^[>\s]+', '', lines[index - 1])
    if _ATTRIBUTION_RE.match(prev):
        return True
    return False


class _SectionState:
    """Mutable state tracker for email section normalisation."""
    __slots__ = ('in_quote_block', 'in_signature', 'in_forwarded')

    def __init__(self):
        self.in_quote_block = False
        self.in_signature = False
        self.in_forwarded = False


def _handle_forwarded_header(result, state):
    """Emit a forwarded-message heading and update state."""
    if state.in_quote_block:
        result.append('')
        state.in_quote_block = False
    state.in_signature = False
    state.in_forwarded = True
    result.append('')
    result.append('## Forwarded Message')
    result.append('')


def _handle_forwarded_body(stripped, result, state):
    """Process a line while inside a forwarded header block.

    Returns True if the line was consumed, False to fall through.
    """
    if state.in_forwarded and _HEADER_FIELD_RE.match(stripped):
        result.append(f'**{stripped}**')
        return True
    if state.in_forwarded and stripped and not _HEADER_FIELD_RE.match(stripped):
        state.in_forwarded = False
        result.append('')
    return False


def _handle_signature(stripped, line, result, state):
    """Process signature-related lines.

    Returns True if the line was consumed, False to fall through.
    """
    if _is_signature_delimiter(stripped):
        if state.in_quote_block:
            result.append('')
            state.in_quote_block = False
        state.in_signature = True
        result.append('')
        result.append('## Signature')
        result.append('')
        return True
    if not state.in_signature:
        return False
    # Inside signature block — check for exit conditions
    if stripped.startswith('>') or re.match(
            r'^-{3,}\s*(Forwarded|Original)', stripped):
        state.in_signature = False
        return False
    result.append(line)
    return True


def _start_quote_block(lines, i, result):
    """Emit a quoted-reply heading if no attribution line precedes this quote."""
    if not _has_attribution_before(lines, i):
        result.append('')
        result.append('## Quoted Reply')
        result.append('')


def _handle_quote_exit(stripped, result):
    """Handle transition out of a quote block on a non-quoted line.

    Returns True if the line was consumed as an attribution, False otherwise.
    """
    if _ATTRIBUTION_RE.match(stripped):
        result.append('')
        result.append('## Quoted Reply')
        result.append('')
        result.append(f'*{stripped}*')
        return True
    return False


def _handle_quoted_line(line, lines, i, result, state):
    """Handle lines that are part of or transitioning from a quote block.

    Returns True if the line was consumed, False to fall through.
    """
    stripped = line.strip()
    if stripped.startswith('>'):
        if not state.in_quote_block:
            state.in_quote_block = True
            _start_quote_block(lines, i, result)
        result.append(line)
        return True

    if state.in_quote_block:
        state.in_quote_block = False
        return _handle_quote_exit(stripped, result)

    return False


def _process_section_line(line, lines, i, result, state):
    """Dispatch a single line through the section-detection pipeline.

    Returns True if the line was consumed by a handler, False to append as-is.
    """
    stripped = line.strip()

    if _is_forwarded_header(stripped):
        _handle_forwarded_header(result, state)
        return True

    consumed = (_handle_forwarded_body(stripped, result, state)
                or _handle_signature(stripped, line, result, state)
                or _handle_quoted_line(line, lines, i, result, state))
    return consumed


def normalise_email_sections(body):
    """Detect and structure email-specific sections in the body text.

    Handles:
    - Quoted replies (lines starting with >)
    - Signature blocks (lines after --)
    - Forwarded message headers (---------- Forwarded message ----------)
    """
    lines = body.splitlines()
    result = []
    state = _SectionState()

    for i, line in enumerate(lines):
        if not _process_section_line(line, lines, i, result, state):
            result.append(line)

    return '\n'.join(result)
