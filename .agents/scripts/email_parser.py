# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email_parser.py - MIME parsing, header extraction, body extraction, and attachment handling.

Part of the email-to-markdown pipeline. Imported by email_to_markdown.py.
"""

import sys
import os
import email
import email.policy
from email import message_from_binary_file
from email.utils import parsedate_to_datetime
import hashlib
import json
import html2text
from pathlib import Path
import mimetypes


def parse_eml(file_path):
    """Parse .eml file using Python's email library."""
    with open(file_path, 'rb') as f:
        msg = message_from_binary_file(f, policy=email.policy.default)
    return msg


def parse_msg(file_path):
    """Parse .msg file using extract_msg library."""
    try:
        import extract_msg
    except ImportError:
        print("ERROR: extract_msg library required for .msg files", file=sys.stderr)
        print("Install: pip install extract-msg", file=sys.stderr)
        sys.exit(1)

    msg = extract_msg.Message(file_path)
    return msg


def _collect_multipart_bodies(msg):
    """Collect text/plain and text/html from a multipart message.

    Returns (body_text, body_html) taking the first occurrence of each type.
    """
    body_text = ""
    body_html = ""
    for part in msg.walk():
        content_type = part.get_content_type()
        if content_type == 'text/plain' and not body_text:
            body_text = part.get_content()
        elif content_type == 'text/html' and not body_html:
            body_html = part.get_content()
    return body_text, body_html


def _collect_singlepart_bodies(msg):
    """Collect text/plain or text/html from a non-multipart message.

    Returns (body_text, body_html).
    """
    content_type = msg.get_content_type()
    if content_type == 'text/plain':
        return msg.get_content(), ""
    if content_type == 'text/html':
        return "", msg.get_content()
    return "", ""


def _extract_mime_parts(msg):
    """Extract text/plain and text/html parts from an email.message.Message.

    Returns (body_text, body_html) taking the first occurrence of each type.
    """
    if msg.is_multipart():
        return _collect_multipart_bodies(msg)
    return _collect_singlepart_bodies(msg)


def _html_to_markdown(html_body):
    """Convert HTML email body to markdown text."""
    h = html2text.HTML2Text()
    h.ignore_links = False
    h.ignore_images = False
    h.ignore_emphasis = False
    h.body_width = 0  # Don't wrap lines
    return h.handle(html_body)


def get_email_body(msg, prefer_html=True):
    """Extract email body, preferring HTML if available."""
    if hasattr(msg, 'body'):  # extract_msg Message object
        body_text = msg.body or ""
        body_html = msg.htmlBody or ""
    else:  # email.message.Message object
        body_text, body_html = _extract_mime_parts(msg)

    if body_html and prefer_html:
        return _html_to_markdown(body_html)

    return body_text


def compute_content_hash(data):
    """Compute SHA-256 hash of binary data.

    Returns the hex digest string for use as a content-addressable key.
    """
    return hashlib.sha256(data).hexdigest()


def load_dedup_registry(registry_path):
    """Load the deduplication registry from a JSON file.

    The registry maps content_hash -> first occurrence path, enabling
    symlink-based deduplication across batch email imports.
    Returns an empty dict if the file doesn't exist.
    """
    if registry_path and os.path.isfile(registry_path):
        with open(registry_path, 'r', encoding='utf-8') as f:
            return json.load(f)
    return {}


def save_dedup_registry(registry, registry_path):
    """Persist the deduplication registry to a JSON file."""
    if registry_path:
        os.makedirs(os.path.dirname(registry_path) or '.', exist_ok=True)
        with open(registry_path, 'w', encoding='utf-8') as f:
            json.dump(registry, f, indent=2)


def _write_file(filepath, data):
    """Write binary data to filepath."""
    with open(filepath, 'wb') as f:
        f.write(data)


def _symlink_attachment(filepath, original_path) -> dict:
    """Create a symlink at filepath pointing to original_path.

    Prefers relative symlinks for portability; falls back to absolute.
    Returns dedup_info dict with 'deduplicated_from' key.
    """
    try:
        rel_target = os.path.relpath(original_path, os.path.dirname(str(filepath)))
        os.symlink(rel_target, str(filepath))
    except OSError:
        os.symlink(original_path, str(filepath))
    return {'deduplicated_from': original_path}


def _save_attachment(filepath, data, content_hash, dedup_registry):
    """Save an attachment, deduplicating via symlink if hash already seen.

    Returns a dict with 'deduplicated_from' set when a duplicate is detected.
    The original file is symlinked rather than copied to save disk space.
    """
    if dedup_registry is None or content_hash not in dedup_registry:
        # First occurrence — write file and register
        _write_file(filepath, data)
        if dedup_registry is not None:
            dedup_registry[content_hash] = str(filepath)
        return {}

    # Duplicate detected — symlink to first occurrence if it still exists
    original_path = dedup_registry[content_hash]
    if os.path.exists(original_path):
        return _symlink_attachment(filepath, original_path)

    # Original no longer exists — write normally and become new canonical
    _write_file(filepath, data)
    dedup_registry[content_hash] = str(filepath)
    return {}


def _process_one_attachment(filename, data, output_path, dedup_registry):
    """Save a single attachment and return its metadata dict."""
    filepath = output_path / filename
    content_hash = compute_content_hash(data)
    dedup_info = _save_attachment(filepath, data, content_hash, dedup_registry)
    att_meta = {
        'filename': filename,
        'path': str(filepath),
        'size': len(data),
        'content_hash': content_hash,
    }
    att_meta.update(dedup_info)
    return att_meta


def _iter_msg_attachments(msg):
    """Yield (filename, data) pairs from an extract_msg Message object."""
    for attachment in msg.attachments:
        filename = attachment.longFilename or attachment.shortFilename or "attachment"
        yield filename, attachment.data


def _iter_eml_attachments(msg):
    """Yield (filename, data) pairs from an email.message.Message object."""
    for part in msg.walk():
        if part.get_content_maintype() == 'multipart':
            continue
        if part.get('Content-Disposition') is None:
            continue
        filename = part.get_filename()
        if filename:
            yield filename, part.get_payload(decode=True)


def extract_attachments(msg, output_dir, dedup_registry=None):
    """Extract attachments from email message with content-hash deduplication.

    Each attachment gets a SHA-256 content_hash. When dedup_registry is provided,
    duplicate attachments are symlinked to the first occurrence instead of being
    written again, and a 'deduplicated_from' field is added to their metadata.
    """
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)

    if hasattr(msg, 'attachments'):  # extract_msg Message object
        att_iter = _iter_msg_attachments(msg)
    else:  # email.message.Message object
        att_iter = _iter_eml_attachments(msg)

    return [
        _process_one_attachment(filename, data, output_path, dedup_registry)
        for filename, data in att_iter
    ]


def get_file_size(file_path):
    """Get file size in bytes."""
    try:
        return os.path.getsize(file_path)
    except OSError:
        return 0


def extract_header_safe(msg, header, default=''):
    """Safely extract an email header, handling both eml and msg formats."""
    if hasattr(msg, 'sender'):  # extract_msg object
        header_map = {
            'From': getattr(msg, 'sender', default),
            'To': getattr(msg, 'to', default),
            'Cc': getattr(msg, 'cc', default),
            'Bcc': getattr(msg, 'bcc', default),
            'Subject': getattr(msg, 'subject', default),
            'Date': getattr(msg, 'date', default),
            'Message-ID': getattr(msg, 'messageId', default),
            'In-Reply-To': getattr(msg, 'inReplyTo', default),
        }
        return header_map.get(header, default) or default
    else:  # email.message.EmailMessage
        return msg.get(header, default) or default


def parse_date_safe(date_str):
    """Parse a date string to ISO format, returning original on failure."""
    if not date_str or date_str == 'Unknown':
        return ''
    try:
        dt = parsedate_to_datetime(date_str)
        return dt.strftime('%Y-%m-%dT%H:%M:%S%z')
    except Exception:
        return str(date_str)


def _parse_email_file(input_path):
    """Parse an email file based on its extension. Exits on unsupported types."""
    ext = input_path.suffix.lower()
    if ext == '.eml':
        return parse_eml(input_path)
    if ext == '.msg':
        return parse_msg(input_path)
    print(f"ERROR: Unsupported file type: {ext}", file=sys.stderr)
    print("Supported: .eml, .msg", file=sys.stderr)
    sys.exit(1)


def _extract_headers(msg):
    """Extract all visible email headers into a flat dict."""
    return {
        'from': extract_header_safe(msg, 'From', 'Unknown'),
        'to': extract_header_safe(msg, 'To', 'Unknown'),
        'cc': extract_header_safe(msg, 'Cc'),
        'bcc': extract_header_safe(msg, 'Bcc'),
        'subject': extract_header_safe(msg, 'Subject', 'No Subject'),
        'message_id': extract_header_safe(msg, 'Message-ID'),
        'in_reply_to': extract_header_safe(msg, 'In-Reply-To'),
        'date_sent_raw': extract_header_safe(msg, 'Date'),
        'date_received_raw': extract_header_safe(msg, 'Received'),
    }


def _parse_received_date(date_received_raw):
    """Extract the date portion from a Received header value."""
    if date_received_raw and ';' in date_received_raw:
        return date_received_raw.rsplit(';', 1)[-1].strip()
    return date_received_raw
