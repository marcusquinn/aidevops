#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
_email_imap_index.py - SQLite metadata index for IMAP messages.

Internal module used by email_imap_adapter.py. Not intended for direct invocation.
Extracted to reduce per-file complexity (GH#18881).
"""

import os
import sqlite3
from pathlib import Path


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

INDEX_DIR = Path.home() / ".aidevops" / ".agent-workspace" / "email-mailbox"
INDEX_DB = INDEX_DIR / "index.db"


# ---------------------------------------------------------------------------
# SQLite metadata index
# ---------------------------------------------------------------------------

def init_index_db(db_path=None):
    """Initialise the SQLite metadata index. Never stores message bodies."""
    if db_path is None:
        db_path = INDEX_DB
    db_path = Path(db_path)
    db_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)

    conn = sqlite3.connect(str(db_path))
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS messages (
            account     TEXT NOT NULL,
            folder      TEXT NOT NULL,
            uid         INTEGER NOT NULL,
            message_id  TEXT,
            date        TEXT,
            from_addr   TEXT,
            to_addr     TEXT,
            subject     TEXT,
            flags       TEXT,
            size        INTEGER DEFAULT 0,
            indexed_at  TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            PRIMARY KEY (account, folder, uid)
        )
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_messages_date
        ON messages (account, date DESC)
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_messages_from
        ON messages (account, from_addr)
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_messages_subject
        ON messages (account, subject)
    """)
    conn.commit()
    # Secure permissions on the database file
    try:
        os.chmod(str(db_path), 0o600)
    except OSError:
        pass
    return conn


def upsert_message(conn, account, folder, uid, headers):
    """Insert or update a message in the metadata index."""
    conn.execute("""
        INSERT INTO messages (account, folder, uid, message_id, date,
                              from_addr, to_addr, subject, flags, size)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (account, folder, uid) DO UPDATE SET
            message_id = excluded.message_id,
            date       = excluded.date,
            from_addr  = excluded.from_addr,
            to_addr    = excluded.to_addr,
            subject    = excluded.subject,
            flags      = excluded.flags,
            size       = excluded.size,
            indexed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
    """, (
        account, folder, uid,
        headers.get("message_id", ""),
        headers.get("date", ""),
        headers.get("from", ""),
        headers.get("to", ""),
        headers.get("subject", ""),
        headers.get("flags", ""),
        headers.get("size", 0),
    ))


def upsert_messages_to_index(account_key, folder, messages):
    """Persist a list of message metadata dicts to the SQLite index."""
    db_conn = init_index_db()
    for msg in messages:
        upsert_message(db_conn, account_key, folder, msg["uid"], msg)
    db_conn.commit()
    db_conn.close()


def incremental_fetch_range(db_conn, account_key, folder) -> str:
    """Determine the UID fetch range for an incremental index sync.

    Returns a range string like '1234:*' or '1:*' if no prior index exists.
    """
    row = db_conn.execute(
        "SELECT MAX(uid) FROM messages WHERE account = ? AND folder = ?",
        (account_key, folder)
    ).fetchone()
    last_uid = row[0] if row and row[0] else 0
    return f"{last_uid + 1}:*" if last_uid > 0 else "1:*"


def sync_messages_to_db(db_conn, account_key, folder, data, parse_fn) -> int:
    """Parse fetch data and upsert messages into the index.

    Args:
        db_conn: SQLite connection to the index database.
        account_key: Account identifier (user@host).
        folder: IMAP folder name.
        data: Raw IMAP FETCH response data.
        parse_fn: Callable to parse FETCH data into message dicts
                  (typically parse_envelope_from_fetch).

    Returns count of messages synced.
    """
    messages = parse_fn(data)
    for msg in messages:
        upsert_message(db_conn, account_key, folder, msg["uid"], msg)
    db_conn.commit()
    return len(messages)
