#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email_send.py — SMTP send helper for case-chase-helper.sh (t2858)

Usage:
    email_send.py --smtp-host HOST --smtp-port PORT --smtp-security STARTTLS|TLS
                  --from FROM_ADDR --to TO_ADDR --subject SUBJECT --body BODY
                  --password PASSWORD [--dry-run]

Output (stdout):
    JSON: {"message_id": "...", "sent_at": "..."}

Security:
    - Password is passed via stdin or --password flag (never via command line history
      in normal use — callers should use stdin where possible)
    - No credentials appear in output or logs
    - Credentials are never stored by this script
"""
import argparse
import email.message
import email.utils
import json
import smtplib
import ssl
import sys
from datetime import datetime, timezone


def parse_args():
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Send a plain-text email via SMTP and return message-id as JSON"
    )
    parser.add_argument("--smtp-host", required=True)
    parser.add_argument("--smtp-port", required=True, type=int)
    parser.add_argument(
        "--smtp-security",
        required=True,
        choices=["STARTTLS", "TLS", "PLAIN"],
        help="TLS=implicit TLS (port 465), STARTTLS=upgrade (port 587), PLAIN=no encryption",
    )
    parser.add_argument("--smtp-user", default="")
    parser.add_argument("--from-addr", required=True, dest="from_addr")
    parser.add_argument("--to-addr", required=True, dest="to_addr")
    parser.add_argument("--subject", required=True)
    parser.add_argument("--body", required=True)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print substituted email to stdout without sending",
    )
    parser.add_argument(
        "--password",
        default="",
        help="SMTP password (prefer passing via stdin for security)",
    )
    return parser.parse_args()


def build_message(from_addr, to_addr, subject, body):
    """Build an EmailMessage from components."""
    msg = email.message.EmailMessage()
    msg["From"] = from_addr
    msg["To"] = to_addr
    msg["Subject"] = subject
    msg["Date"] = email.utils.formatdate(localtime=False)
    msg["Message-ID"] = email.utils.make_msgid()
    msg.set_content(body)
    return msg


def send_via_tls(host, port, user, password, msg):
    """Send via implicit TLS (port 465)."""
    context = ssl.create_default_context()
    with smtplib.SMTP_SSL(host, port, context=context) as smtp:
        if user:
            smtp.login(user, password)
        smtp.send_message(msg)


def send_via_starttls(host, port, user, password, msg):
    """Send via STARTTLS (port 587)."""
    context = ssl.create_default_context()
    with smtplib.SMTP(host, port) as smtp:
        smtp.ehlo()
        smtp.starttls(context=context)
        smtp.ehlo()
        if user:
            smtp.login(user, password)
        smtp.send_message(msg)


def send_via_plain(host, port, user, password, msg):
    """Send without encryption (test/local relay only)."""
    with smtplib.SMTP(host, port) as smtp:
        smtp.ehlo()
        if user:
            smtp.login(user, password)
        smtp.send_message(msg)


def main():
    """Main entry point."""
    args = parse_args()

    # If --dry-run, print what would be sent to stderr and return JSON to stdout
    if args.dry_run:
        print("--- DRY RUN: email not sent ---", file=sys.stderr)
        print(f"From: {args.from_addr}", file=sys.stderr)
        print(f"To: {args.to_addr}", file=sys.stderr)
        print(f"Subject: {args.subject}", file=sys.stderr)
        print("", file=sys.stderr)
        print(args.body, file=sys.stderr)
        result = {
            "dry_run": True,
            "message_id": "<dry-run@local>",
            "sent_at": datetime.now(timezone.utc).isoformat(),
        }
        print(json.dumps(result))
        sys.exit(0)

    msg = build_message(args.from_addr, args.to_addr, args.subject, args.body)
    message_id = msg["Message-ID"]

    password = args.password
    # If password empty, read from stdin (more secure — avoids shell history)
    if not password and not sys.stdin.isatty():
        password = sys.stdin.readline().rstrip("\n")

    try:
        security = args.smtp_security.upper()
        smtp_user = args.smtp_user if args.smtp_user else args.from_addr
        if security == "TLS":
            send_via_tls(args.smtp_host, args.smtp_port, smtp_user, password, msg)
        elif security == "STARTTLS":
            send_via_starttls(
                args.smtp_host, args.smtp_port, smtp_user, password, msg
            )
        else:
            send_via_plain(args.smtp_host, args.smtp_port, smtp_user, password, msg)
    except smtplib.SMTPException as exc:
        error_result = {
            "error": str(exc),
            "message_id": None,
            "sent_at": None,
        }
        print(json.dumps(error_result), file=sys.stdout)
        sys.exit(1)
    except OSError as exc:
        error_result = {
            "error": f"Connection error: {exc}",
            "message_id": None,
            "sent_at": None,
        }
        print(json.dumps(error_result), file=sys.stdout)
        sys.exit(1)

    sent_at = datetime.now(timezone.utc).isoformat()
    result = {
        "message_id": message_id,
        "sent_at": sent_at,
    }
    print(json.dumps(result))
    sys.exit(0)


if __name__ == "__main__":
    main()
