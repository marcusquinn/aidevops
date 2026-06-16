#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# email_parse.py — Parse .eml/.emlx files into structured JSON for knowledge ingestion
#
# Usage:
#   python3 email_parse.py <eml-path> [--output-dir <dir>]
#
# Outputs JSON to stdout:
#   { "from", "to", "cc", "bcc", "date", "subject", "message_id",
#     "in_reply_to", "references", "body_text_path", "body_html_path",
#     "attachments": [{"filename", "content_path", "content_type", "size"}] }
#
# Body text/html are written to --output-dir (default: temp dir).
# Attachments are written to --output-dir/attachments/.

import email
import email.policy
import json
import os
import re
import sys
import tempfile
from html.parser import HTMLParser


class _HTMLTextExtractor(HTMLParser):
    """Minimal HTML-to-text extractor using stdlib only."""

    def __init__(self):
        super().__init__()
        self._pieces = []
        self._skip = False

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self._skip = True
        if tag in ("br", "p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6"):
            self._pieces.append("\n")
        return None

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self._skip = False
        return None

    def handle_data(self, data):
        if not self._skip:
            self._pieces.append(data)
        return None

    def get_text(self):
        return re.sub(r"\n{3,}", "\n\n", "".join(self._pieces)).strip()


def html_to_text(html_content):
    """Convert HTML to plain text using stdlib HTMLParser."""
    extractor = _HTMLTextExtractor()
    try:
        extractor.feed(html_content)
    except Exception:
        # Fallback: strip tags with regex
        return re.sub(r"<[^>]+>", "", html_content).strip()
    return extractor.get_text()


def strip_emlx_header(raw_bytes):
    """Strip Apple Mail .emlx length-prefix header before parsing.

    .emlx format prepends a decimal byte-count line followed by a newline.
    """
    first_newline = raw_bytes.find(b"\n")
    if first_newline < 0 or first_newline > 20:
        return raw_bytes
    prefix = raw_bytes[:first_newline].strip()
    if prefix.isdigit():
        return raw_bytes[first_newline + 1:]
    return raw_bytes


def extract_headers(msg):
    """Extract standard email headers into a dict."""
    headers = {}
    for field in ("from", "to", "cc", "bcc", "date", "subject",
                  "message-id", "in-reply-to", "references"):
        value = msg.get(field, "")
        if value:
            headers[field.replace("-", "_")] = str(value)
        else:
            headers[field.replace("-", "_")] = ""
    return headers


def extract_body_parts(msg, output_dir):
    """Walk MIME parts and extract text/html bodies and attachments.

    Returns (body_text_path, body_html_path, attachments_list).
    """
    body_text, body_html, attachments = _collect_body_content(msg, output_dir)
    body_text_path, body_html_path = _write_body_files(output_dir, body_text, body_html)
    return body_text_path, body_html_path, attachments


def _collect_body_content(msg, output_dir):
    """Collect first text/plain, first text/html, and attachments from a message."""
    bodies = {"text/plain": "", "text/html": ""}
    attachments = []
    att_dir = os.path.join(output_dir, "attachments")

    for part in msg.walk():
        content_type = part.get_content_type()
        disposition = str(part.get("Content-Disposition", ""))
        filename = part.get_filename()

        # Attachment: explicit disposition or named inline part (not text body)
        if _is_attachment(disposition, filename, content_type):
            attachments.append(
                _save_attachment(part, filename, content_type, att_dir, len(attachments))
            )
            continue

        _capture_body_part(part, content_type, bodies)

    return bodies["text/plain"], bodies["text/html"], attachments


def _capture_body_part(part, content_type, bodies):
    """Capture the first decoded text or HTML body for a MIME part."""
    if content_type in bodies and not bodies[content_type]:
        payload = _decode_payload(part)
        if payload:
            bodies[content_type] = payload


def _write_body_files(output_dir, body_text, body_html):
    """Write extracted body files and return their paths."""
    if not body_text and body_html:
        body_text = html_to_text(body_html)

    body_text_path = ""
    body_html_path = ""

    if body_text:
        body_text_path = os.path.join(output_dir, "body_text.txt")
        _write_file(body_text_path, body_text)

    if body_html:
        body_html_path = os.path.join(output_dir, "body_html.html")
        _write_file(body_html_path, body_html)

    return body_text_path, body_html_path


def _is_attachment(disposition, filename, content_type):
    """Determine if a MIME part is an attachment."""
    if "attachment" in disposition.lower():
        return True
    if filename and content_type not in ("text/plain", "text/html"):
        return True
    return False


def _decode_payload(part):
    """Safely decode a MIME part payload to string."""
    try:
        payload = part.get_content()
    except Exception:
        payload = _fallback_payload(part)
    return _normalise_payload(payload)


def _normalise_payload(payload):
    """Convert MIME payload data to text."""
    if isinstance(payload, bytes):
        return _decode_bytes(payload)
    return str(payload) if payload else ""


def _decode_bytes(payload):
    """Decode bytes with UTF-8 first, then latin-1 fallback."""
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError:
        text = payload.decode("latin-1", errors="replace")
    return text


def _fallback_payload(part):
    """Fallback to decoded raw payload when get_content fails."""
    try:
        return part.get_payload(decode=True) or b""
    except Exception:
        return b""


def _save_attachment(part, filename, content_type, att_dir, index):
    """Save an attachment to disk and return metadata dict."""
    os.makedirs(att_dir, exist_ok=True)
    if not filename:
        ext = content_type.split("/")[-1] if "/" in content_type else "bin"
        filename = "attachment-{}.{}".format(index, ext)
    # Sanitise filename
    filename = re.sub(r"[/\\:\x00]", "_", filename)
    att_path = os.path.join(att_dir, filename)
    try:
        payload = part.get_payload(decode=True)
        if payload is None:
            payload = b""
    except Exception:
        payload = b""
    _write_file_bytes(att_path, payload)
    return {
        "filename": filename,
        "content_path": att_path,
        "content_type": content_type,
        "size": len(payload),
    }


def _write_file(path, content):
    """Write text content to a file."""
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(content)


def _write_file_bytes(path, content):
    """Write binary content to a file."""
    with open(path, "wb") as fh:
        fh.write(content)


def parse_eml(eml_path, output_dir=None):
    """Parse an .eml or .emlx file and return structured result dict."""
    if output_dir is None:
        output_dir = tempfile.mkdtemp(prefix="email_parse_")

    os.makedirs(output_dir, exist_ok=True)

    with open(eml_path, "rb") as fh:
        raw_bytes = fh.read()

    # Handle .emlx format (Apple Mail)
    if eml_path.lower().endswith(".emlx"):
        raw_bytes = strip_emlx_header(raw_bytes)

    msg = email.message_from_bytes(raw_bytes, policy=email.policy.default)
    headers = extract_headers(msg)
    body_text_path, body_html_path, attachments = extract_body_parts(msg, output_dir)

    result = dict(headers)
    result["body_text_path"] = body_text_path
    result["body_html_path"] = body_html_path
    result["attachments"] = attachments
    return result


def main():
    """CLI entry point."""
    if len(sys.argv) < 2:
        print("Usage: email_parse.py <eml-path> [--output-dir <dir>]", file=sys.stderr)
        sys.exit(1)

    eml_path = sys.argv[1]
    output_dir = None

    i = 2
    while i < len(sys.argv):
        if sys.argv[i] == "--output-dir" and i + 1 < len(sys.argv):
            output_dir = sys.argv[i + 1]
            i += 2
        else:
            i += 1

    if not os.path.isfile(eml_path):
        print("Error: file not found: {}".format(eml_path), file=sys.stderr)
        sys.exit(1)

    result = parse_eml(eml_path, output_dir)
    json.dump(result, sys.stdout, indent=2, ensure_ascii=False)
    print()  # trailing newline


if __name__ == "__main__":
    main()
