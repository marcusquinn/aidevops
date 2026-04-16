# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email_normaliser_sections.py - Email section normalisation and thread reconstruction.

Extracted from email_normaliser.py to reduce file-level complexity.
Provides detection and structuring of email-specific sections (quoted
replies, signatures, forwarded messages) and thread reconstruction from
In-Reply-To/Message-ID headers.
"""

import json
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Tuple

from email_parser import (
    parse_eml,
    parse_msg,
    extract_header_safe,
    parse_date_safe,
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


# ---------------------------------------------------------------------------
# Thread reconstruction
# ---------------------------------------------------------------------------

def _parse_email_thread_headers(email_file: Path) -> dict:
    """Parse thread-relevant headers from a single email file."""
    ext = email_file.suffix.lower()
    msg = parse_eml(email_file) if ext == '.eml' else parse_msg(email_file)
    return {
        'message_id': extract_header_safe(msg, 'Message-ID'),
        'in_reply_to': extract_header_safe(msg, 'In-Reply-To'),
        'date_sent': parse_date_safe(extract_header_safe(msg, 'Date')),
        'subject': extract_header_safe(msg, 'Subject', 'No Subject'),
    }


def build_thread_map(emails_dir: Path) -> Dict[str, Dict]:
    """Build a map of all emails by message-id for thread reconstruction."""
    thread_map = {}

    for ext in ['.eml', '.msg']:
        for email_file in emails_dir.glob(f'**/*{ext}'):
            try:
                headers = _parse_email_thread_headers(email_file)
                if headers['message_id']:
                    thread_map[headers['message_id']] = {
                        'file_path': str(email_file),
                        'in_reply_to': headers['in_reply_to'],
                        'date_sent': headers['date_sent'],
                        'subject': headers['subject'],
                    }
            except Exception as e:
                print(f"Warning: Failed to parse {email_file}: {e}", file=sys.stderr)
                continue

    return thread_map


def _next_ancestor(current_id: str, thread_map: Dict[str, Dict],
                    visited: set) -> str:
    """Return the parent message_id of current_id, or '' if none/cycle."""
    info = thread_map.get(current_id)
    if not info:
        return ''
    parent = info.get('in_reply_to', '')
    if not parent or parent not in thread_map or parent in visited:
        return ''
    return parent


def _walk_ancestor_chain(message_id: str, thread_map: Dict[str, Dict]) -> List[str]:
    """Walk backwards from message_id to the thread root via in_reply_to."""
    current_id = message_id
    chain = [current_id]
    visited = {current_id}

    while True:
        parent = _next_ancestor(current_id, thread_map, visited)
        if not parent:
            break
        chain.insert(0, parent)
        visited.add(parent)
        current_id = parent

    return chain


def _count_descendants(msg_id: str, thread_map: Dict[str, Dict],
                       visited_desc: set) -> int:
    """Recursively count all descendants of msg_id in the thread map."""
    if msg_id in visited_desc:
        return 0
    visited_desc.add(msg_id)

    count = 1
    for mid, info in thread_map.items():
        if info.get('in_reply_to') == msg_id and mid not in visited_desc:
            count += _count_descendants(mid, thread_map, visited_desc)
    return count


def reconstruct_thread(message_id: str, thread_map: Dict[str, Dict]) -> Tuple[str, int, int]:
    """Reconstruct thread information for a given message.

    Returns: (thread_id, thread_position, thread_length)
    """
    if not message_id or message_id not in thread_map:
        return ('', 0, 0)

    chain = _walk_ancestor_chain(message_id, thread_map)
    thread_id = chain[0]
    thread_position = chain.index(message_id) + 1
    thread_length = _count_descendants(thread_id, thread_map, set())

    return (thread_id, thread_position, thread_length)


def _group_emails_by_thread(thread_map: Dict[str, Dict]) -> dict:
    """Group all emails in thread_map by their thread_id."""
    threads: dict = defaultdict(list)
    for message_id, info in thread_map.items():
        thread_id, position, length = reconstruct_thread(message_id, thread_map)
        if thread_id:
            threads[thread_id].append({
                'message_id': message_id,
                'file_path': info['file_path'],
                'subject': info['subject'],
                'date_sent': info['date_sent'],
                'thread_position': position,
                'thread_length': length
            })
    for thread_id in threads:
        threads[thread_id].sort(key=lambda x: x['date_sent'] or '')
    return threads


def _write_thread_index_files(threads: dict, threads_dir: Path) -> None:
    """Write one JSON index file per thread into threads_dir."""
    threads_dir.mkdir(parents=True, exist_ok=True)
    for thread_id, emails in threads.items():
        safe_thread_id = re.sub(r'[<>:/\\|?*]', '_', thread_id)
        index_file = threads_dir / f'{safe_thread_id}.json'
        with open(index_file, 'w', encoding='utf-8') as f:
            json.dump({
                'thread_id': thread_id,
                'thread_length': len(emails),
                'emails': emails
            }, f, indent=2, ensure_ascii=False)


def generate_thread_index(thread_map: Dict[str, Dict], output_dir: Path) -> Dict[str, List[Dict]]:
    """Generate thread index files grouped by thread_id."""
    threads = _group_emails_by_thread(thread_map)
    _write_thread_index_files(threads, output_dir / 'threads')
    return dict(threads)
