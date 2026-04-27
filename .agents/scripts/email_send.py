#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email_send.py — SMTP send helper for case chase emails (t2858).

Reads a .eml.tmpl template, substitutes {{field}} placeholders from
--fields-json, and sends via STARTTLS SMTP. No LLM at send time.

Usage:
  email_send.py --template <path> --fields-json '<json>' \\
                --smtp-host <host> --smtp-port <port> --smtp-user <user> \\
                --smtp-pass-env <ENV_VAR> [--dry-run]

Output (success): JSON to stdout: {"message_id": "...", "sent_at": "..."}
Output (error): message to stderr, exit 1
"""

import argparse
import json
import os
import re
import smtplib
import sys
from datetime import datetime, timezone
from email.message import EmailMessage


def parse_args():
    """Parse command-line arguments."""
    p = argparse.ArgumentParser(description="Send chase email via SMTP")
    p.add_argument("--template", required=True, help="Path to .eml.tmpl file")
    p.add_argument("--fields-json", required=True, help="JSON object of field values")
    p.add_argument("--smtp-host", default="", help="SMTP server hostname")
    p.add_argument("--smtp-port", type=int, default=587, help="SMTP port (default: 587)")
    p.add_argument("--smtp-user", default="", help="SMTP username")
    p.add_argument("--smtp-pass-env", default="CHASE_SMTP_PASS",
                   help="Env var holding SMTP password")
    p.add_argument("--dry-run", action="store_true",
                   help="Print substituted email to stdout, no send")
    return p.parse_args()


def load_template(template_path):
    """Load template file, stripping leading comment lines (starting with #)."""
    if not os.path.isfile(template_path):
        print(f"Template not found: {template_path}", file=sys.stderr)
        sys.exit(1)
    with open(template_path, encoding="utf-8") as fh:
        lines = fh.readlines()
    content_lines = []
    for line in lines:
        if line.startswith("#") and not content_lines:
            continue  # Skip header comments before first non-comment line
        content_lines.append(line)
    return "".join(content_lines)


def substitute_fields(template_content, fields):
    """Replace {{field}} placeholders with values from fields dict."""
    def replacer(match):
        key = match.group(1)
        return fields.get(key, match.group(0))  # Leave unresolved placeholders as-is

    return re.sub(r"\{\{([a-zA-Z_][a-zA-Z0-9_]*)\}\}", replacer, template_content)


def parse_email_headers(content):
    """Parse RFC 5322 headers from template content.

    Returns (headers_dict, body_str). Headers end at first blank line.
    """
    parts = content.split("\n\n", 1)
    header_block = parts[0]
    body = parts[1] if len(parts) > 1 else ""

    headers = {}
    for line in header_block.splitlines():
        if ":" in line:
            key, _, val = line.partition(":")
            headers[key.strip()] = val.strip()
    return headers, body


def build_message(headers, body):
    """Build an EmailMessage from parsed headers and body."""
    msg = EmailMessage()
    msg["From"] = headers.get("From", "")
    msg["To"] = headers.get("To", "")
    msg["Subject"] = headers.get("Subject", "")

    for hdr in ("Cc", "Bcc", "Reply-To", "X-Mailer"):
        if hdr in headers:
            msg[hdr] = headers[hdr]

    msg.set_content(body.strip())
    return msg


def send_smtp(msg, smtp_host, smtp_port, smtp_user, smtp_pass):
    """Send message via STARTTLS SMTP. Returns message-id string."""
    if not smtp_host:
        print("SMTP host not configured", file=sys.stderr)
        sys.exit(1)

    with smtplib.SMTP(smtp_host, smtp_port, timeout=30) as server:
        server.ehlo()
        server.starttls()
        server.ehlo()
        if smtp_user and smtp_pass:
            server.login(smtp_user, smtp_pass)
        server.send_message(msg)

    message_id = (
        msg.get("Message-ID")
        or f"<chase-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}@aidevops>"
    )
    return message_id


def main():
    """Entry point."""
    args = parse_args()

    try:
        fields = json.loads(args.fields_json)
    except json.JSONDecodeError as exc:
        print(f"Invalid --fields-json: {exc}", file=sys.stderr)
        sys.exit(1)

    raw = load_template(args.template)
    substituted = substitute_fields(raw, fields)

    if args.dry_run:
        print(substituted)
        sys.exit(0)

    headers, body = parse_email_headers(substituted)

    for required in ("From", "To", "Subject"):
        if not headers.get(required):
            print(f"Missing required header: {required}", file=sys.stderr)
            sys.exit(1)

    msg = build_message(headers, body)
    smtp_pass = os.environ.get(args.smtp_pass_env, "")

    try:
        message_id = send_smtp(
            msg, args.smtp_host, args.smtp_port, args.smtp_user, smtp_pass
        )
    except smtplib.SMTPException as exc:
        print(f"SMTP error: {exc}", file=sys.stderr)
        sys.exit(1)
    except OSError as exc:
        print(f"Connection error: {exc}", file=sys.stderr)
        sys.exit(1)

    sent_at = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    result = {"message_id": message_id, "sent_at": sent_at}
    print(json.dumps(result))


if __name__ == "__main__":
    main()
