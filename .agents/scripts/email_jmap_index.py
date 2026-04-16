#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email_jmap_index.py - SQLite metadata index for JMAP email operations.

Extracted from email_jmap_adapter.py to reduce file-level complexity.
Shared with the IMAP adapter for the messages table schema.
"""

import os
import sqlite3
from pathlib import Path


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

INDEX_DIR = Path.home() / ".aidevops" / ".agent-workspace" / "email-mailbox"
INDEX_DB = INDEX_DIR / "index.db"

_SYNC_STATE_UPSERT = (
    "INSERT INTO jmap_sync_state (account, mailbox_id, state) "
    "VALUES (?, ?, ?) "
    "ON CONFLICT (account, mailbox_id) DO UPDATE SET "
    "state = excluded.state, "
    "updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')"
)


# ---------------------------------------------------------------------------
# Table creation
# ---------------------------------------------------------------------------

def _create_messages_table(conn):
    """Create the messages table if it does not exist."""
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


def _create_jmap_emails_table(conn):
    """Create the jmap_emails table and its indexes if they do not exist."""
    conn.execute("""
        CREATE TABLE IF NOT EXISTS jmap_emails (
            account     TEXT NOT NULL,
            email_id    TEXT NOT NULL,
            thread_id   TEXT,
            blob_id     TEXT,
            mailbox_ids TEXT,
            message_id  TEXT,
            date        TEXT,
            from_addr   TEXT,
            to_addr     TEXT,
            subject     TEXT,
            keywords    TEXT,
            size        INTEGER DEFAULT 0,
            preview     TEXT,
            indexed_at  TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            PRIMARY KEY (account, email_id)
        )
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_jmap_emails_date
        ON jmap_emails (account, date DESC)
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_jmap_emails_from
        ON jmap_emails (account, from_addr)
    """)
    conn.execute("""
        CREATE INDEX IF NOT EXISTS idx_jmap_emails_thread
        ON jmap_emails (account, thread_id)
    """)


def _create_sync_state_table(conn):
    """Create the jmap_sync_state table if it does not exist."""
    conn.execute("""
        CREATE TABLE IF NOT EXISTS jmap_sync_state (
            account     TEXT NOT NULL,
            mailbox_id  TEXT NOT NULL,
            state       TEXT NOT NULL,
            updated_at  TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            PRIMARY KEY (account, mailbox_id)
        )
    """)


# ---------------------------------------------------------------------------
# Index initialisation and upsert
# ---------------------------------------------------------------------------

def _init_index_db(db_path=None):
    """Initialise the SQLite metadata index. Never stores message bodies."""
    if db_path is None:
        db_path = INDEX_DB
    db_path = Path(db_path)
    db_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)

    conn = sqlite3.connect(str(db_path))
    conn.execute("PRAGMA journal_mode=WAL")
    _create_messages_table(conn)
    _create_jmap_emails_table(conn)
    _create_sync_state_table(conn)
    conn.commit()
    try:
        os.chmod(str(db_path), 0o600)
    except OSError:
        pass
    return conn


def _upsert_jmap_email(conn, account, email_data):
    """Insert or update a JMAP email in the metadata index."""
    from_addrs = email_data.get("from") or []
    from_str = ", ".join(
        f"{a.get('name', '')} <{a.get('email', '')}>".strip()
        for a in from_addrs
    ) if from_addrs else ""

    to_addrs = email_data.get("to") or []
    to_str = ", ".join(
        f"{a.get('name', '')} <{a.get('email', '')}>".strip()
        for a in to_addrs
    ) if to_addrs else ""

    keywords = email_data.get("keywords") or {}
    keywords_str = " ".join(sorted(keywords.keys()))

    mailbox_ids = email_data.get("mailboxIds") or {}
    mailbox_str = ",".join(sorted(mailbox_ids.keys()))

    conn.execute("""
        INSERT INTO jmap_emails
            (account, email_id, thread_id, blob_id, mailbox_ids,
             message_id, date, from_addr, to_addr, subject,
             keywords, size, preview)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (account, email_id) DO UPDATE SET
            thread_id   = excluded.thread_id,
            blob_id     = excluded.blob_id,
            mailbox_ids = excluded.mailbox_ids,
            message_id  = excluded.message_id,
            date        = excluded.date,
            from_addr   = excluded.from_addr,
            to_addr     = excluded.to_addr,
            subject     = excluded.subject,
            keywords    = excluded.keywords,
            size        = excluded.size,
            preview     = excluded.preview,
            indexed_at  = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
    """, (
        account,
        email_data.get("id", ""),
        email_data.get("threadId", ""),
        email_data.get("blobId", ""),
        mailbox_str,
        _first_or_empty(email_data.get("messageId")),
        email_data.get("receivedAt", ""),
        from_str,
        to_str,
        email_data.get("subject", ""),
        keywords_str,
        email_data.get("size", 0),
        email_data.get("preview", ""),
    ))


def _first_or_empty(val):
    """Extract first element from a list or return empty string."""
    if isinstance(val, list) and val:
        return val[0]
    if isinstance(val, str):
        return val
    return ""
