#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Read-only sent-mail collection for the voice miner.

Pattern analysis, credential lookup and profile output belong to the CLI;
this module handles only IMAP connection, folder discovery and message parsing.
"""

import email
import email.errors
import email.policy
import imaplib
import sys
from typing import Optional


SENT_FOLDER_CANDIDATES = [
    "Sent",
    "Sent Items",
    "Sent Messages",
    "[Gmail]/Sent Mail",
    "INBOX.Sent",
    "Sent Mail",
]


def connect_imap(host: str, port: int, user: str, password: str) -> imaplib.IMAP4_SSL:
    """Connect and authenticate to IMAP server via SSL."""
    try:
        conn = imaplib.IMAP4_SSL(host, port)
    except (OSError, imaplib.IMAP4.error) as exc:
        print(f"ERROR: Cannot connect to {host}:{port} — {exc}", file=sys.stderr)
        sys.exit(1)

    try:
        conn.login(user, password)
    except imaplib.IMAP4.error as exc:
        print(f"ERROR: IMAP login failed for {user} — {exc}", file=sys.stderr)
        sys.exit(1)

    return conn


def _decode_folder_entry(raw) -> str:
    """Decode a raw IMAP folder list entry into a string."""
    if isinstance(raw, bytes):
        return raw.decode("utf-8", errors="replace")
    return str(raw)


def _extract_folder_name(decoded: str) -> Optional[str]:
    """Extract folder name from IMAP LIST response line."""
    parts = decoded.rsplit('"', 2)
    if len(parts) >= 2:
        return parts[-1].strip()
    return None


def _list_imap_folders(folders) -> list:
    """Parse IMAP LIST response into list of (flags, name) tuples."""
    result = []
    for folder_entry in folders or []:
        decoded = _decode_folder_entry(folder_entry)
        name = _extract_folder_name(decoded)
        if name:
            result.append((decoded, name))
    return result


def _find_sent_by_special_use(folders) -> Optional[str]:
    """Find sent folder using IMAP SPECIAL-USE \\Sent attribute."""
    for flags_line, name in folders:
        if "\\Sent" in flags_line:
            return name
    return None


def _find_sent_by_name(available: list) -> Optional[str]:
    """Find sent folder by matching common folder names."""
    available_lower = {n.lower(): n for _, n in available}
    for candidate in SENT_FOLDER_CANDIDATES:
        if candidate.lower() in available_lower:
            return available_lower[candidate.lower()]
    return None


def detect_sent_folder(
    conn: imaplib.IMAP4_SSL,
    verbose: bool = False,
) -> Optional[str]:
    """Auto-detect the sent folder name using SPECIAL-USE or common names."""
    status, folders_raw = conn.list()
    if status != "OK" or not folders_raw:
        return None

    folders = _list_imap_folders(folders_raw)

    sent = _find_sent_by_special_use(folders)
    if sent:
        return sent

    return _find_sent_by_name(folders)


def _select_imap_folder(conn: imaplib.IMAP4_SSL, folder: str) -> None:
    """Select an IMAP folder, exiting on failure."""
    status, data = conn.select(folder, readonly=True)
    if status != "OK":
        print(f"ERROR: Cannot select folder '{folder}': {data}", file=sys.stderr)
        sys.exit(1)


def _fetch_message_ids(conn: imaplib.IMAP4_SSL) -> list:
    """Fetch all message UIDs from the currently selected folder."""
    status, data = conn.search(None, "ALL")
    if status != "OK" or not data[0]:
        return []
    return data[0].split()


def _parse_fetched_message(msg_id, msg_data, verbose: bool):
    """Parse a raw IMAP fetch response into an email.message.Message."""
    for part in msg_data:
        if isinstance(part, tuple) and len(part) >= 2:
            try:
                return email.message_from_bytes(
                    part[1],
                    policy=email.policy.default,
                )
            except (email.errors.MessageError, UnicodeDecodeError):
                if verbose:
                    print(f"  WARNING: Could not parse message {msg_id}", file=sys.stderr)
    return None


def fetch_sent_emails(
    conn: imaplib.IMAP4_SSL,
    folder: str,
    limit: int,
    verbose: bool = False,
) -> list:
    """Fetch up to `limit` sent emails from the IMAP server.

    Returns a list of email.message.Message objects.
    """
    _select_imap_folder(conn, folder)
    msg_ids = _fetch_message_ids(conn)
    if not msg_ids:
        return []

    # Take the most recent messages
    msg_ids = msg_ids[-limit:]

    messages = []
    for msg_id in msg_ids:
        status, msg_data = conn.fetch(msg_id, "(RFC822)")
        if status != "OK":
            continue
        msg = _parse_fetched_message(msg_id, msg_data, verbose)
        if msg:
            messages.append(msg)

    return messages
