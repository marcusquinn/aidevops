# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email_normaliser.py - Email section normalisation, thread reconstruction, and frontmatter building.

Part of the email-to-markdown pipeline. Imported by email_to_markdown.py.
"""

import sys
import json
import re
from pathlib import Path
from typing import Dict, List, Tuple
from collections import defaultdict

from email_parser import (
    parse_eml,
    parse_msg,
    extract_header_safe,
    parse_date_safe,
)


# ---------------------------------------------------------------------------
# YAML utilities
# ---------------------------------------------------------------------------

def format_size(size_bytes):
    """Format file size in human-readable format."""
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size_bytes < 1024.0:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024.0
    return f"{size_bytes:.1f} TB"


def estimate_tokens(text):
    """Estimate token count using word-based heuristic (words * 1.3).

    This approximates GPT/Claude tokenization without requiring tiktoken.
    The 1.3 multiplier accounts for subword tokenization of punctuation,
    numbers, and multi-syllable words.
    """
    if not text:
        return 0
    words = len(text.split())
    return int(words * 1.3)


def yaml_escape(value):
    """Escape a string value for safe YAML output.

    Wraps in double quotes if the value contains characters that could
    break YAML parsing (colons, quotes, newlines, leading special chars).
    """
    if value is None:
        return '""'
    value = str(value)
    if not value:
        return '""'
    # Quote if contains YAML-special characters or starts with special chars
    needs_quoting = any(c in value for c in [
        ':', '#', '{', '}', '[', ']', ',', '&', '*', '?', '|', '-',
        '<', '>', '=', '!', '%', '@', '`', '\n', '\r', '"', "'"
    ])
    needs_quoting = needs_quoting or value.startswith((' ', '\t'))
    if needs_quoting:
        # Escape backslashes and double quotes for YAML double-quoted strings
        value = value.replace('\\', '\\\\').replace('"', '\\"')
        # Replace newlines with spaces
        value = value.replace('\n', ' ').replace('\r', '')
        return f'"{value}"'
    return value


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
    """Check if the previous line has an 'On ... wrote:' attribution pattern.

    Handles re-quoted emails where the previous line may itself be
    quote-marked (e.g., '> On date, user wrote:') by stripping leading
    '>' characters and whitespace before matching.
    """
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

def build_thread_map(emails_dir: Path) -> Dict[str, Dict]:
    """Build a map of all emails by message-id for thread reconstruction.

    Returns a dict mapping message_id -> {file_path, in_reply_to, date_sent, subject}
    """
    thread_map = {}

    # Find all .eml and .msg files
    for ext in ['.eml', '.msg']:
        for email_file in emails_dir.glob(f'**/*{ext}'):
            try:
                # Parse just the headers we need
                if ext == '.eml':
                    msg = parse_eml(email_file)
                else:
                    msg = parse_msg(email_file)

                message_id = extract_header_safe(msg, 'Message-ID')
                in_reply_to = extract_header_safe(msg, 'In-Reply-To')
                date_sent_raw = extract_header_safe(msg, 'Date')
                subject = extract_header_safe(msg, 'Subject', 'No Subject')

                if message_id:
                    thread_map[message_id] = {
                        'file_path': str(email_file),
                        'in_reply_to': in_reply_to,
                        'date_sent': parse_date_safe(date_sent_raw),
                        'subject': subject
                    }
            except Exception as e:
                print(f"Warning: Failed to parse {email_file}: {e}", file=sys.stderr)
                continue

    return thread_map


def _walk_ancestor_chain(message_id: str, thread_map: Dict[str, Dict]) -> List[str]:
    """Walk backwards from message_id to the thread root via in_reply_to.

    Returns the chain of message IDs from root to message_id, inclusive.
    """
    current_id = message_id
    chain = [current_id]
    visited = {current_id}

    while True:
        current_info = thread_map.get(current_id)
        if not current_info:
            break
        in_reply_to = current_info.get('in_reply_to', '')
        if not in_reply_to or in_reply_to not in thread_map:
            break
        if in_reply_to in visited:
            break
        chain.insert(0, in_reply_to)
        visited.add(in_reply_to)
        current_id = in_reply_to

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
    - thread_id: message-id of the root message (first in thread)
    - thread_position: 1-based position in thread (1 = root)
    - thread_length: total number of messages in thread
    """
    if not message_id or message_id not in thread_map:
        return ('', 0, 0)

    chain = _walk_ancestor_chain(message_id, thread_map)
    thread_id = chain[0]
    thread_position = chain.index(message_id) + 1
    thread_length = _count_descendants(thread_id, thread_map, set())

    return (thread_id, thread_position, thread_length)


def generate_thread_index(thread_map: Dict[str, Dict], output_dir: Path) -> Dict[str, List[Dict]]:
    """Generate thread index files grouped by thread_id.

    Returns a dict mapping thread_id -> list of email metadata in chronological order.
    Writes one index file per thread to output_dir/threads/
    """
    # Group emails by thread
    threads = defaultdict(list)

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

    # Sort each thread by date
    for thread_id in threads:
        threads[thread_id].sort(key=lambda x: x['date_sent'] or '')

    # Write thread index files
    threads_dir = output_dir / 'threads'
    threads_dir.mkdir(parents=True, exist_ok=True)

    for thread_id, emails in threads.items():
        # Sanitize thread_id for filename (remove angle brackets, slashes)
        safe_thread_id = re.sub(r'[<>:/\\|?*]', '_', thread_id)
        index_file = threads_dir / f'{safe_thread_id}.json'

        with open(index_file, 'w', encoding='utf-8') as f:
            json.dump({
                'thread_id': thread_id,
                'thread_length': len(emails),
                'emails': emails
            }, f, indent=2, ensure_ascii=False)

    return dict(threads)


# ---------------------------------------------------------------------------
# Frontmatter building
# ---------------------------------------------------------------------------

def _format_attachment_yaml(att):
    """Format a single attachment dict as indented YAML list-item lines."""
    lines = [f'  - filename: {yaml_escape(att["filename"])}']
    lines.append(f'    size: {yaml_escape(att["size"])}')
    if 'content_hash' in att:
        lines.append(f'    content_hash: {att["content_hash"]}')
    if 'deduplicated_from' in att:
        lines.append(f'    deduplicated_from: {yaml_escape(att["deduplicated_from"])}')
    return lines


def _format_attachments_yaml(key, attachments):
    """Format the attachments list as YAML lines."""
    if not attachments:
        return [f'{key}: []']
    lines = [f'{key}:']
    for att in attachments:
        lines.extend(_format_attachment_yaml(att))
    return lines


def _format_entities_yaml(key, entities):
    """Format the entities dict-of-lists as YAML lines."""
    if not entities:
        return [f'{key}: {{}}']
    lines = [f'{key}:']
    for entity_type, entity_list in entities.items():
        if not entity_list:
            continue
        lines.append(f'  {entity_type}:')
        for entity in entity_list:
            lines.append(f'    - {yaml_escape(entity)}')
    return lines


def build_frontmatter(metadata):
    """Build YAML frontmatter string from metadata dict.

    Handles scalar values, lists of dicts (attachments with content_hash
    and optional deduplicated_from), nested dicts of lists (entities),
    and proper YAML escaping for all string values.
    """
    lines = ['---']
    for key, value in metadata.items():
        if key == 'attachments' and isinstance(value, list):
            lines.extend(_format_attachments_yaml(key, value))
        elif key == 'entities' and isinstance(value, dict):
            lines.extend(_format_entities_yaml(key, value))
        elif isinstance(value, (int, float)):
            lines.append(f'{key}: {value}')
        else:
            lines.append(f'{key}: {yaml_escape(value)}')
    lines.append('---')
    return '\n'.join(lines)
