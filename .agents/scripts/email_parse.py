#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email_parse.py - Parse .eml files and output structured JSON.

Reads an .eml (or .emlx) file, extracts headers, body parts, and attachments,
then outputs a JSON object to stdout suitable for ingestion by
email-ingest-helper.sh.

Usage:
    python3 email_parse.py <eml-path> [--output-dir <dir>]

Output JSON schema:
    {
        "from": "sender@example.com",
        "to": "recipient@example.com",
        "cc": "",
        "bcc": "",
        "subject": "Hello",
        "date": "2026-04-25T10:00:00+0000",
        "message_id": "<abc@example.com>",
        "in_reply_to": "",
        "references": "",
        "body_text_path": "/tmp/email-xyz/body.txt",
        "body_html_path": "/tmp/email-xyz/body.html",
        "attachments": [
            {
                "filename": "doc.pdf",
                "content_path": "/tmp/email-xyz/doc.pdf",
                "content_type": "application/pdf",
                "size": 12345
            }
        ]
    }
"""

import email
import email.header
import email.policy
import email.utils
import json
import os
import re
import sys
import tempfile
from html.parser import HTMLParser
from io import StringIO


# ---------------------------------------------------------------------------
# HTML-to-text fallback (no external deps)
# ---------------------------------------------------------------------------

class _HTMLTextExtractor(HTMLParser):
    """Minimal HTML tag stripper for extracting plain text from HTML bodies."""

    def __init__(self):
        super().__init__()
        self._pieces = []
        self._skip = False

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self._skip = True
        elif tag == "br":
            self._pieces.append("\n")
        elif tag in ("p", "div", "tr", "li"):
            self._pieces.append("\n")

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self._skip = False
        elif tag in ("p", "div", "tr"):
            self._pieces.append("\n")

    def handle_data(self, data):
        if not self._skip:
            self._pieces.append(data)

    def get_text(self):
        return "".join(self._pieces).strip()


def html_to_text(html_content):
    """Convert HTML to plain text using stdlib HTMLParser."""
    extractor = _HTMLTextExtractor()
    try:
        extractor.feed(html_content)
        return extractor.get_text()
    except Exception:
        # Last resort: strip tags with regex
        text = re.sub(r"<[^>]+>", " ", html_content)
        return re.sub(r"\s+", " ", text).strip()


# ---------------------------------------------------------------------------
# Header decoding
# ---------------------------------------------------------------------------

def decode_header_value(raw):
    """Decode an RFC 2047 encoded header value to unicode string."""
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


def parse_date(date_header):
    """Parse an email Date header to ISO 8601 format."""
    if not date_header:
        return ""
    try:
        dt = email.utils.parsedate_to_datetime(str(date_header))
        return dt.strftime("%Y-%m-%dT%H:%M:%S%z")
    except (ValueError, TypeError):
        return str(date_header)


# ---------------------------------------------------------------------------
# .emlx support (Apple Mail)
# ---------------------------------------------------------------------------

def strip_emlx_header(raw_bytes):
    """Strip Apple Mail .emlx length-header prefix.

    .emlx files have a decimal byte count on the first line followed by a
    newline, then standard RFC 5322 content. After the RFC 5322 portion there
    may be an Apple plist trailer which we also strip.
    """
    # Find first newline — everything before it should be a decimal number
    newline_pos = raw_bytes.find(b"\n")
    if newline_pos < 0 or newline_pos > 20:
        # Doesn't look like an .emlx header
        return raw_bytes
    first_line = raw_bytes[:newline_pos].strip()
    if not first_line.isdigit():
        return raw_bytes
    byte_count = int(first_line)
    start = newline_pos + 1
    # Extract exactly byte_count bytes of RFC 5322 content
    end = start + byte_count
    if end > len(raw_bytes):
        end = len(raw_bytes)
    return raw_bytes[start:end]


# ---------------------------------------------------------------------------
# MIME walking
# ---------------------------------------------------------------------------

def extract_parts(msg, output_dir):
    """Walk MIME parts and extract body text, body HTML, and attachments.

    Returns (body_text, body_html, attachments_list).
    """
    body_text = ""
    body_html = ""
    attachments = []

    for part in msg.walk():
        content_type = part.get_content_type()
        content_disp = str(part.get("Content-Disposition") or "")
        filename = part.get_filename()

        # Decode filename if encoded
        if filename:
            filename = decode_header_value(filename)

        is_attachment = (
            "attachment" in content_disp.lower()
            or (filename and "inline" not in content_disp.lower())
            or (filename and content_type not in ("text/plain", "text/html"))
        )

        if is_attachment and filename:
            # Save attachment to output_dir
            payload = part.get_payload(decode=True)
            if payload is None:
                continue
            # Sanitise filename
            safe_name = re.sub(r'[/\\<>:"|?*\x00-\x1f]', '_', filename)
            if not safe_name:
                safe_name = "attachment"
            att_path = os.path.join(output_dir, safe_name)
            # Handle duplicate filenames
            counter = 1
            base, ext = os.path.splitext(att_path)
            while os.path.exists(att_path):
                att_path = f"{base}_{counter}{ext}"
                counter += 1
            with open(att_path, "wb") as f:
                f.write(payload)
            attachments.append({
                "filename": safe_name,
                "content_path": att_path,
                "content_type": content_type,
                "size": len(payload),
            })
        elif content_type == "text/plain" and not body_text:
            payload = part.get_payload(decode=True)
            if payload:
                charset = part.get_content_charset() or "utf-8"
                try:
                    body_text = payload.decode(charset, errors="replace")
                except (LookupError, UnicodeDecodeError):
                    body_text = payload.decode("utf-8", errors="replace")
        elif content_type == "text/html" and not body_html:
            payload = part.get_payload(decode=True)
            if payload:
                charset = part.get_content_charset() or "utf-8"
                try:
                    body_html = payload.decode(charset, errors="replace")
                except (LookupError, UnicodeDecodeError):
                    body_html = payload.decode("utf-8", errors="replace")

    return body_text, body_html, attachments


# ---------------------------------------------------------------------------
# Main parse function
# ---------------------------------------------------------------------------

def parse_eml(eml_path, output_dir=None):
    """Parse an .eml or .emlx file and return structured data.

    Args:
        eml_path: Path to the .eml or .emlx file.
        output_dir: Directory for extracted body/attachment files.
                    Created as a temp dir if not provided.

    Returns:
        dict with email metadata, body paths, and attachment list.
    """
    if output_dir is None:
        output_dir = tempfile.mkdtemp(prefix="email-parse-")
    else:
        os.makedirs(output_dir, exist_ok=True)

    with open(eml_path, "rb") as f:
        raw_bytes = f.read()

    # Handle .emlx (Apple Mail) format
    if eml_path.lower().endswith(".emlx"):
        raw_bytes = strip_emlx_header(raw_bytes)

    msg = email.message_from_bytes(raw_bytes, policy=email.policy.default)

    # Extract headers
    result = {
        "from": decode_header_value(msg.get("From", "")),
        "to": decode_header_value(msg.get("To", "")),
        "cc": decode_header_value(msg.get("Cc", "")),
        "bcc": decode_header_value(msg.get("Bcc", "")),
        "subject": decode_header_value(msg.get("Subject", "")),
        "date": parse_date(msg.get("Date", "")),
        "message_id": str(msg.get("Message-ID", "")),
        "in_reply_to": str(msg.get("In-Reply-To", "")),
        "references": str(msg.get("References", "")),
        "body_text_path": None,
        "body_html_path": None,
        "attachments": [],
    }

    # Extract body and attachments
    body_text, body_html, attachments = extract_parts(msg, output_dir)

    # If HTML-only, generate plain text from HTML
    if not body_text and body_html:
        body_text = html_to_text(body_html)

    # Write body files
    if body_text:
        text_path = os.path.join(output_dir, "body.txt")
        with open(text_path, "w", encoding="utf-8") as f:
            f.write(body_text)
        result["body_text_path"] = text_path

    if body_html:
        html_path = os.path.join(output_dir, "body.html")
        with open(html_path, "w", encoding="utf-8") as f:
            f.write(body_html)
        result["body_html_path"] = html_path

    result["attachments"] = attachments

    return result


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        print("Usage: email_parse.py <eml-path> [--output-dir <dir>]", file=sys.stderr)
        sys.exit(1)

    eml_path = sys.argv[1]
    output_dir = None

    # Parse --output-dir flag
    i = 2
    while i < len(sys.argv):
        if sys.argv[i] == "--output-dir" and i + 1 < len(sys.argv):
            output_dir = sys.argv[i + 1]
            i += 2
        else:
            i += 1

    if not os.path.isfile(eml_path):
        print(f"Error: file not found: {eml_path}", file=sys.stderr)
        sys.exit(1)

    result = parse_eml(eml_path, output_dir)
    json.dump(result, sys.stdout, indent=2, ensure_ascii=False)
    print()  # trailing newline


if __name__ == "__main__":
    main()
