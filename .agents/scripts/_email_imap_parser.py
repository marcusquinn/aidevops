#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
_email_imap_parser.py - IMAP response and MIME parsing helpers.

Internal module used by email_imap_adapter.py. Not intended for direct invocation.
Extracted to reduce per-file complexity (GH#18881).
"""

import email
import email.header
import email.policy
import email.utils
import re


# ---------------------------------------------------------------------------
# Header parsing
# ---------------------------------------------------------------------------

def decode_header_value(raw):
    """Decode an RFC 2047 encoded header value."""
    if raw is None:
        return ""
    parts = email.header.decode_header(raw)
    decoded = []
    for part_bytes, charset in parts:
        if isinstance(part_bytes, bytes):
            decoded.append(part_bytes.decode(charset or "utf-8", errors="replace"))
        else:
            decoded.append(str(part_bytes))
    return " ".join(decoded)


def parse_imap_date(date_header) -> str:
    """Parse an IMAP Date header to ISO 8601 format.

    Returns the ISO string on success, or the raw header string on failure.
    """
    if not date_header:
        return ""
    try:
        dt = email.utils.parsedate_to_datetime(str(date_header))
        return dt.strftime("%Y-%m-%dT%H:%M:%S%z")
    except (ValueError, TypeError):
        return str(date_header)


def parse_response_line_fields(response_line) -> tuple:
    """Extract UID, flags string, and size from an IMAP FETCH response line.

    Returns (uid, flags_str, size) tuple.
    """
    uid_match = re.search(rb"UID (\d+)", response_line)
    uid = int(uid_match.group(1)) if uid_match else 0

    flags_match = re.search(rb"FLAGS \(([^)]*)\)", response_line)
    flags_str = (
        flags_match.group(1).decode("utf-8", errors="replace")
        if flags_match else ""
    )

    size_match = re.search(rb"RFC822\.SIZE (\d+)", response_line)
    size = int(size_match.group(1)) if size_match else 0

    return uid, flags_str, size


def parse_header_bytes(header_bytes, uid, flags_str, size) -> dict:
    """Parse raw header bytes into a message metadata dict."""
    msg = email.message_from_bytes(header_bytes, policy=email.policy.default)
    return {
        "uid": uid,
        "message_id": str(msg.get("Message-ID", "")),
        "date": parse_imap_date(msg.get("Date", "")),
        "from": str(msg.get("From", "")),
        "to": str(msg.get("To", "")),
        "subject": str(msg.get("Subject", "")),
        "flags": flags_str,
        "size": size,
    }


def parse_envelope_from_fetch(fetch_data):
    """Parse headers from an IMAP FETCH response.

    Uses BODY.PEEK[HEADER.FIELDS (...)] to avoid marking as read.
    """
    results = []
    for item in fetch_data:
        if not (isinstance(item, tuple) and len(item) == 2):
            continue
        response_line, header_bytes = item
        uid, flags_str, size = parse_response_line_fields(response_line)
        if isinstance(header_bytes, bytes):
            results.append(parse_header_bytes(header_bytes, uid, flags_str, size))
    return results


# ---------------------------------------------------------------------------
# MIME body extraction
# ---------------------------------------------------------------------------

def decode_part_payload(part) -> str:
    """Decode a MIME part's payload to a string using its declared charset."""
    raw_payload = part.get_payload(decode=True)
    if not isinstance(raw_payload, bytes):
        return ""
    charset = part.get_content_charset() or "utf-8"
    return raw_payload.decode(charset, errors="replace")


def extract_multipart_bodies(msg) -> tuple:
    """Extract text, html, and attachment metadata from a multipart message.

    Returns (text_body, html_body, attachments).
    """
    text_body = ""
    html_body = ""
    attachments = []

    for part in msg.walk():
        content_type = part.get_content_type()
        disposition = str(part.get("Content-Disposition", ""))

        if "attachment" in disposition:
            attachments.append({
                "filename": part.get_filename() or "unnamed",
                "content_type": content_type,
                "size": len(part.get_payload(decode=True) or b""),
            })
        elif content_type == "text/plain" and not text_body:
            text_body = decode_part_payload(part)
        elif content_type == "text/html" and not html_body:
            html_body = decode_part_payload(part)

    return text_body, html_body, attachments


def extract_singlepart_bodies(msg) -> tuple:
    """Extract text or html body from a non-multipart message.

    Returns (text_body, html_body, attachments=[]).
    """
    content_type = msg.get_content_type()
    decoded = decode_part_payload(msg)
    if content_type == "text/plain":
        return decoded, "", []
    if content_type == "text/html":
        return "", decoded, []
    return "", "", []


def extract_message_bodies(msg) -> tuple:
    """Dispatch body extraction based on whether message is multipart.

    Returns (text_body, html_body, attachments).
    """
    if msg.is_multipart():
        return extract_multipart_bodies(msg)
    return extract_singlepart_bodies(msg)


# ---------------------------------------------------------------------------
# Folder entry parsing
# ---------------------------------------------------------------------------

def parse_folder_entry(item, reverse_mapping):
    """Parse a single IMAP LIST response entry into a folder dict, or None."""
    if item is None:
        return None
    decoded = item.decode("utf-8", errors="replace") if isinstance(item, bytes) else str(item)
    match = re.match(r'\(([^)]*)\)\s+"([^"]+)"\s+"?([^"]*)"?', decoded)
    if not match:
        return None
    name = match.group(3).strip('"')
    return {
        "name": name,
        "logical_name": reverse_mapping.get(name, ""),
        "flags": match.group(1),
        "delimiter": match.group(2),
    }
