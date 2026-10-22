#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Read-only IMAP UID transport for the knowledge-plane poller.

This module searches and parses server responses only. Collection admission,
receipts, inbox writes and cursor transactions remain in email_poll.
"""

from __future__ import annotations

import imaplib
import re
from datetime import datetime


def _connect_imap(host: str, port: int, user: str, password: str) -> imaplib.IMAP4_SSL:
    """Open an IMAP4_SSL connection and authenticate."""
    conn = imaplib.IMAP4_SSL(host, port)
    conn.login(user, password)
    return conn


def _search_uids_since(
    conn: imaplib.IMAP4_SSL,
    folder: str,
    last_uid: int,
    max_uids: int = 0,
    since_date: str = "",
) -> tuple[list[int], dict[str, object]]:
    """SELECT folder and return UIDs > last_uid, optionally capped at max_uids.

    Returns selected UIDs and content-free scan evidence. Raises RuntimeError on
    IMAP errors.
    """
    status, _ = conn.select(f'"{folder}"', readonly=True)
    if status != "OK":
        raise RuntimeError(f"SELECT '{folder}' failed: {status}")

    start_uid = last_uid + 1
    criteria = f"UID {start_uid}:*"
    if since_date:
        imap_date = datetime.strptime(since_date, "%Y-%m-%d").strftime("%d-%b-%Y")
        criteria = f"{criteria} SINCE {imap_date}"
    status, data = conn.uid("SEARCH", None, criteria)  # type: ignore[arg-type]
    if status != "OK":
        raise RuntimeError(f"UID SEARCH failed: {status}")

    uid_list_raw = data[0] if data else b""
    uid_strings = uid_list_raw.decode().split() if uid_list_raw else []
    # Filter: server may return * = UIDNEXT-1 when the range is empty
    valid_uids = [int(u) for u in uid_strings if int(u) > last_uid]
    candidate_total = len(valid_uids)
    has_more = max_uids > 0 and candidate_total > max_uids
    evidence: dict[str, object] = {
        "candidate_total": candidate_total,
        "has_more": has_more,
        "backfill_truncated": last_uid == 0 and has_more,
        "mode": "initial" if last_uid == 0 else "incremental",
    }

    if max_uids > 0:
        # A new rule lineage performs one bounded recent-history replay, then
        # checkpoints the high UID so later ticks collect only new mail.
        valid_uids = valid_uids[-max_uids:] if last_uid == 0 else valid_uids[:max_uids]

    return valid_uids, evidence


def _uid_fetch_selected(
    conn: imaplib.IMAP4_SSL, valid_uids: list[int]
) -> list[tuple[int, bytes]]:
    """Fetch one sorted union of already-selected candidate UIDs."""
    if not valid_uids:
        return []
    uid_set = ",".join(str(uid) for uid in valid_uids)
    status, fetch_data = conn.uid("FETCH", uid_set, "(BODY.PEEK[])")  # type: ignore[arg-type]
    if status != "OK":
        raise RuntimeError(f"UID FETCH failed: {status}")
    return _parse_fetch_response(fetch_data, valid_uids)


def _parse_fetch_response(
    fetch_data: list, valid_uids: list, last_uid: int = 0
) -> list[tuple[int, bytes]]:
    """Parse an imaplib RFC822 FETCH response into (uid, raw_bytes) tuples.

    Returns list[tuple[int, bytes]], sorted by UID ascending.
    Only includes messages with UID > last_uid (use last_uid=0 for all).
    """
    messages = []
    i = 0
    while i < len(fetch_data):
        item = fetch_data[i]
        if isinstance(item, tuple):
            header_part = item[0]
            raw_msg = item[1]
            uid_match = re.search(rb"UID\s+(\d+)", header_part)
            if uid_match:
                uid = int(uid_match.group(1))
            else:
                # Fallback: infer from position in valid_uids
                uid = valid_uids[len(messages)] if len(messages) < len(valid_uids) else 0
            if uid > last_uid:
                messages.append((uid, raw_msg))
        i += 1

    messages.sort(key=lambda t: t[0])
    return messages


def _uid_fetch_since(
    conn: imaplib.IMAP4_SSL, folder: str, last_uid: int, max_uids: int = 0
) -> list[tuple[int, bytes]]:
    """Fetch messages with UID > last_uid in folder.

    Args:
        max_uids: If > 0, fetch at most this many messages (oldest first).
                  Used by cmd_test to avoid fetching entire mailboxes.

    Returns a list of (uid, raw_rfc822_bytes) tuples sorted by UID ascending.
    """
    valid_uids, _evidence = _search_uids_since(conn, folder, last_uid, max_uids)
    if not valid_uids:
        return []

    return _uid_fetch_selected(conn, valid_uids)


def _uid_fetch_since_date(
    conn: imaplib.IMAP4_SSL, folder: str, since_date: str, max_uids: int = 0
) -> list[tuple[int, bytes]]:
    """Fetch all messages in folder with INTERNALDATE >= since_date.

    since_date: ISO date string, e.g. '2026-01-01'.
    Returns (uid, raw_rfc822) tuples sorted by UID ascending.
    """
    status, _ = conn.select(f'"{folder}"', readonly=True)
    if status != "OK":
        raise RuntimeError(f"SELECT '{folder}' failed: {status}")

    # IMAP SEARCH date format: DD-Mon-YYYY (e.g. 01-Jan-2026)
    dt = datetime.strptime(since_date, "%Y-%m-%d")
    imap_date = dt.strftime("%d-%b-%Y")

    status, data = conn.uid("SEARCH", None, f"SINCE {imap_date}")  # type: ignore[arg-type]
    if status != "OK":
        raise RuntimeError(f"UID SEARCH SINCE failed: {status}")

    uid_list_raw = data[0]
    if not uid_list_raw:
        return []

    uid_strings = uid_list_raw.decode().split()
    if not uid_strings:
        return []

    valid_uids = [int(u) for u in uid_strings]
    if not valid_uids:
        return []
    if max_uids > 0:
        valid_uids = valid_uids[-max_uids:]

    uid_set = ",".join(str(u) for u in valid_uids)
    status, fetch_data = conn.uid("FETCH", uid_set, "(BODY.PEEK[])")  # type: ignore[arg-type]
    if status != "OK":
        raise RuntimeError(f"UID FETCH failed: {status}")

    # last_uid=0 → keep all messages (UIDs are always >= 1)
    return _parse_fetch_response(fetch_data, valid_uids, last_uid=0)
