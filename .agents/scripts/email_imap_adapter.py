#!/usr/bin/env python3
"""
email_imap_adapter.py - IMAP adapter for mailbox operations.

Provides IMAP connection, header fetching, body fetching, search, move,
and flag operations. Uses BODY.PEEK to avoid marking messages as read.

Part of the email mailbox helper (t1493). Called by email-mailbox-helper.sh.

Usage:
    python3 email_imap_adapter.py connect --host HOST --port PORT --user USER
    python3 email_imap_adapter.py fetch_headers --folder INBOX [--limit 50] [--offset 0]
    python3 email_imap_adapter.py fetch_body --uid UID [--folder INBOX]
    python3 email_imap_adapter.py search --query "FROM sender@example.com" [--folder INBOX]
    python3 email_imap_adapter.py list_folders
    python3 email_imap_adapter.py create_folder --folder "Archive/Projects/acme"
    python3 email_imap_adapter.py move_message --uid UID --dest "Archive" [--folder INBOX]
    python3 email_imap_adapter.py set_flag --uid UID --flag "$Task" [--folder INBOX]
    python3 email_imap_adapter.py clear_flag --uid UID --flag "$Task" [--folder INBOX]
    python3 email_imap_adapter.py index_sync --folder INBOX [--full]

Credentials: read from IMAP_PASSWORD environment variable (never from argv).
Provider config: read from PROVIDER_CONFIG_JSON environment variable or --provider-config file.

Output: JSON to stdout. Errors to stderr.
"""

import argparse
import email
import email.header
import email.policy
import email.utils
import imaplib
import json
import os
import re
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

INDEX_DIR = Path.home() / ".aidevops" / ".agent-workspace" / "email-mailbox"
INDEX_DB = INDEX_DIR / "index.db"

# Custom flag taxonomy mapping (from email-mailbox.md)
FLAG_TAXONOMY = {
    "Reminders": "$Reminder",
    "Tasks": "$Task",
    "Review": "$Review",
    "Filing": "$Filing",
    "Ideas": "$Idea",
    "Add-to-Contacts": "$AddContact",
}

# IMAP date format for SEARCH commands
IMAP_DATE_FMT = "%d-%b-%Y"


# ---------------------------------------------------------------------------
# SQLite metadata index
# ---------------------------------------------------------------------------

def _init_index_db(db_path=None):
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


def _upsert_message(conn, account, folder, uid, headers):
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


# ---------------------------------------------------------------------------
# IMAP connection
# ---------------------------------------------------------------------------

def _get_password():
    """Read IMAP password from environment variable. Never from argv."""
    password = os.environ.get("IMAP_PASSWORD", "")
    if not password:
        print("ERROR: IMAP_PASSWORD environment variable not set", file=sys.stderr)
        print("Set it via: IMAP_PASSWORD=$(gopass show -o email-imap-account) python3 ...",
              file=sys.stderr)
        sys.exit(1)
    return password


def connect(host, port, user, security="TLS"):
    """Connect and authenticate to an IMAP server.

    Args:
        host: IMAP server hostname.
        port: IMAP server port (993 for TLS, 143 for STARTTLS).
        user: IMAP username (usually email address).
        security: "TLS" (implicit) or "STARTTLS".

    Returns:
        Authenticated imaplib.IMAP4_SSL or IMAP4 connection.
    """
    password = _get_password()

    try:
        if security.upper() == "TLS":
            conn = imaplib.IMAP4_SSL(host, int(port))
        else:
            conn = imaplib.IMAP4(host, int(port))
            conn.starttls()

        conn.login(user, password)
        return conn
    except imaplib.IMAP4.error as exc:
        print(f"ERROR: IMAP connection failed: {exc}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:
        print(f"ERROR: Connection error: {exc}", file=sys.stderr)
        sys.exit(1)


def _parse_provider_config(provider_config_path=None):
    """Load provider config from file or PROVIDER_CONFIG_JSON env var."""
    config_json = os.environ.get("PROVIDER_CONFIG_JSON", "")
    if config_json:
        try:
            return json.loads(config_json)
        except json.JSONDecodeError as exc:
            print(f"ERROR: Invalid PROVIDER_CONFIG_JSON: {exc}", file=sys.stderr)
            sys.exit(1)

    if provider_config_path and os.path.isfile(provider_config_path):
        with open(provider_config_path, "r", encoding="utf-8") as fh:
            return json.load(fh)

    return {}


def _get_folder_mapping(provider_config):
    """Extract folder name mapping from provider config."""
    return provider_config.get("default_folders", {})


# ---------------------------------------------------------------------------
# Header parsing
# ---------------------------------------------------------------------------

def _decode_header_value(raw):
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


def _parse_envelope_from_fetch(fetch_data):
    """Parse headers from an IMAP FETCH response.

    Uses BODY.PEEK[HEADER.FIELDS (...)] to avoid marking as read.
    """
    results = []
    # fetch_data is a list of (response_line, data) tuples
    idx = 0
    while idx < len(fetch_data):
        item = fetch_data[idx]
        if isinstance(item, tuple) and len(item) == 2:
            response_line = item[0]
            header_bytes = item[1]

            # Extract UID from response line
            uid_match = re.search(rb"UID (\d+)", response_line)
            uid = int(uid_match.group(1)) if uid_match else 0

            # Extract FLAGS from response line
            flags_match = re.search(rb"FLAGS \(([^)]*)\)", response_line)
            flags_str = flags_match.group(1).decode("utf-8", errors="replace") if flags_match else ""

            # Extract RFC822.SIZE from response line
            size_match = re.search(rb"RFC822\.SIZE (\d+)", response_line)
            size = int(size_match.group(1)) if size_match else 0

            # Parse headers
            if isinstance(header_bytes, bytes):
                msg = email.message_from_bytes(header_bytes, policy=email.policy.default)
                date_str = ""
                date_header = msg.get("Date", "")
                if date_header:
                    try:
                        dt = email.utils.parsedate_to_datetime(str(date_header))
                        date_str = dt.strftime("%Y-%m-%dT%H:%M:%S%z")
                    except (ValueError, TypeError):
                        date_str = str(date_header)

                results.append({
                    "uid": uid,
                    "message_id": str(msg.get("Message-ID", "")),
                    "date": date_str,
                    "from": str(msg.get("From", "")),
                    "to": str(msg.get("To", "")),
                    "subject": str(msg.get("Subject", "")),
                    "flags": flags_str,
                    "size": size,
                })
        idx += 1
    return results


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_connect(args):
    """Test IMAP connectivity and report server capabilities."""
    conn = connect(args.host, args.port, args.user, args.security)
    # Get capabilities
    caps = conn.capabilities
    cap_list = [c.decode("utf-8") if isinstance(c, bytes) else str(c) for c in caps]

    result = {
        "status": "connected",
        "host": args.host,
        "port": args.port,
        "user": args.user,
        "capabilities": cap_list,
    }
    conn.logout()
    print(json.dumps(result, indent=2))
    return 0


def cmd_fetch_headers(args):
    """Fetch message headers from a folder using BODY.PEEK (no read marking)."""
    conn = connect(args.host, args.port, args.user, args.security)
    folder = args.folder or "INBOX"
    limit = args.limit or 50
    offset = args.offset or 0

    status, count_data = conn.select(f'"{folder}"', readonly=True)
    if status != "OK":
        print(f"ERROR: Cannot select folder '{folder}': {count_data}", file=sys.stderr)
        conn.logout()
        return 1

    total = int(count_data[0] or b"0")
    if total == 0:
        print(json.dumps({"folder": folder, "total": 0, "messages": []}))
        conn.logout()
        return 0

    # Calculate range (most recent first)
    end = max(1, total - offset)
    start = max(1, end - limit + 1)

    # Use UID FETCH with BODY.PEEK to avoid marking as read
    fetch_range = f"{start}:{end}"
    status, data = conn.fetch(
        fetch_range,
        "(UID FLAGS RFC822.SIZE BODY.PEEK[HEADER.FIELDS "
        "(Date From To Subject Message-ID In-Reply-To References)])"
    )

    if status != "OK":
        print(f"ERROR: FETCH failed: {data}", file=sys.stderr)
        conn.logout()
        return 1

    messages = _parse_envelope_from_fetch(data)
    # Sort by UID descending (most recent first)
    messages.sort(key=lambda m: m["uid"], reverse=True)

    # Update SQLite index
    account_key = f"{args.user}@{args.host}"
    db_conn = _init_index_db()
    for msg in messages:
        _upsert_message(db_conn, account_key, folder, msg["uid"], msg)
    db_conn.commit()
    db_conn.close()

    result = {
        "folder": folder,
        "total": total,
        "offset": offset,
        "limit": limit,
        "returned": len(messages),
        "messages": messages,
    }
    print(json.dumps(result, indent=2))
    conn.logout()
    return 0


def cmd_fetch_body(args):
    """Fetch a single message body by UID using BODY.PEEK."""
    conn = connect(args.host, args.port, args.user, args.security)
    folder = args.folder or "INBOX"

    status, _ = conn.select(f'"{folder}"', readonly=True)
    if status != "OK":
        print(f"ERROR: Cannot select folder '{folder}'", file=sys.stderr)
        conn.logout()
        return 1

    # Fetch full message using BODY.PEEK (doesn't mark as read)
    status, data = conn.uid("FETCH", str(args.uid), "(BODY.PEEK[])")
    if status != "OK" or not data or data[0] is None:
        print(f"ERROR: Message UID {args.uid} not found", file=sys.stderr)
        conn.logout()
        return 1

    raw_email = data[0][1] if isinstance(data[0], tuple) else b""
    msg = email.message_from_bytes(raw_email, policy=email.policy.default)

    # Extract text parts
    text_body = ""
    html_body = ""
    attachments = []

    if msg.is_multipart():
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
                raw_payload = part.get_payload(decode=True)
                if isinstance(raw_payload, bytes):
                    charset = part.get_content_charset() or "utf-8"
                    text_body = raw_payload.decode(charset, errors="replace")
            elif content_type == "text/html" and not html_body:
                raw_payload = part.get_payload(decode=True)
                if isinstance(raw_payload, bytes):
                    charset = part.get_content_charset() or "utf-8"
                    html_body = raw_payload.decode(charset, errors="replace")
    else:
        content_type = msg.get_content_type()
        raw_payload = msg.get_payload(decode=True)
        if isinstance(raw_payload, bytes):
            charset = msg.get_content_charset() or "utf-8"
            decoded = raw_payload.decode(charset, errors="replace")
            if content_type == "text/plain":
                text_body = decoded
            elif content_type == "text/html":
                html_body = decoded

    result = {
        "uid": args.uid,
        "folder": folder,
        "message_id": str(msg.get("Message-ID", "")),
        "date": str(msg.get("Date", "")),
        "from": str(msg.get("From", "")),
        "to": str(msg.get("To", "")),
        "cc": str(msg.get("Cc", "")),
        "subject": str(msg.get("Subject", "")),
        "in_reply_to": str(msg.get("In-Reply-To", "")),
        "references": str(msg.get("References", "")),
        "text_body": text_body,
        "html_body_length": len(html_body),
        "attachments": attachments,
    }
    print(json.dumps(result, indent=2))
    conn.logout()
    return 0


def cmd_search(args):
    """Search messages using IMAP SEARCH criteria."""
    conn = connect(args.host, args.port, args.user, args.security)
    folder = args.folder or "INBOX"

    status, _ = conn.select(f'"{folder}"', readonly=True)
    if status != "OK":
        print(f"ERROR: Cannot select folder '{folder}'", file=sys.stderr)
        conn.logout()
        return 1

    # Build IMAP search criteria
    criteria = args.query
    if not criteria:
        print("ERROR: --query is required for search", file=sys.stderr)
        conn.logout()
        return 1

    status, data = conn.uid("SEARCH", "CHARSET", "UTF-8", criteria)
    if status != "OK":
        print(f"ERROR: SEARCH failed: {data}", file=sys.stderr)
        conn.logout()
        return 1

    uid_list = data[0].split() if data[0] else []
    # Limit results
    limit = args.limit or 50
    uid_list = uid_list[-limit:]  # Most recent UIDs

    messages = []
    if uid_list:
        uid_str = b",".join(uid_list).decode("utf-8")
        status, fetch_data = conn.uid(
            "FETCH", uid_str,
            "(UID FLAGS RFC822.SIZE BODY.PEEK[HEADER.FIELDS "
            "(Date From To Subject Message-ID)])"
        )
        if status == "OK":
            messages = _parse_envelope_from_fetch(fetch_data)
            messages.sort(key=lambda m: m["uid"], reverse=True)

    result = {
        "folder": folder,
        "query": criteria,
        "total_matches": len(uid_list),
        "returned": len(messages),
        "messages": messages,
    }
    print(json.dumps(result, indent=2))
    conn.logout()
    return 0


def cmd_list_folders(args):
    """List all IMAP folders with provider-aware name mapping."""
    conn = connect(args.host, args.port, args.user, args.security)

    status, folder_data = conn.list()
    if status != "OK":
        print("ERROR: LIST failed", file=sys.stderr)
        conn.logout()
        return 1

    provider_config = _parse_provider_config(args.provider_config)
    folder_mapping = _get_folder_mapping(provider_config)
    # Invert mapping for display: imap_name -> logical_name
    reverse_mapping = {v: k for k, v in folder_mapping.items()}

    folders = []
    for item in folder_data:
        if item is None:
            continue
        decoded = item.decode("utf-8", errors="replace") if isinstance(item, bytes) else str(item)
        # Parse IMAP LIST response: (flags) delimiter name
        match = re.match(r'\(([^)]*)\)\s+"([^"]+)"\s+"?([^"]*)"?', decoded)
        if match:
            flags_str = match.group(1)
            delimiter = match.group(2)
            name = match.group(3).strip('"')
            logical_name = reverse_mapping.get(name, "")
            folders.append({
                "name": name,
                "logical_name": logical_name,
                "flags": flags_str,
                "delimiter": delimiter,
            })

    result = {
        "total": len(folders),
        "folder_mapping": folder_mapping,
        "folders": folders,
    }
    print(json.dumps(result, indent=2))
    conn.logout()
    return 0


def cmd_create_folder(args):
    """Create an IMAP folder (mailbox)."""
    conn = connect(args.host, args.port, args.user, args.security)
    folder = args.folder
    if not folder:
        print("ERROR: --folder is required", file=sys.stderr)
        conn.logout()
        return 1

    status, data = conn.create(f'"{folder}"')
    if status != "OK":
        print(f"ERROR: CREATE failed: {data}", file=sys.stderr)
        conn.logout()
        return 1

    # Subscribe to the new folder
    conn.subscribe(f'"{folder}"')

    result = {"status": "created", "folder": folder}
    print(json.dumps(result, indent=2))
    conn.logout()
    return 0


def cmd_move_message(args):
    """Move a message to a destination folder by UID."""
    conn = connect(args.host, args.port, args.user, args.security)
    folder = args.folder or "INBOX"
    dest = args.dest
    uid = str(args.uid)

    if not dest:
        print("ERROR: --dest is required", file=sys.stderr)
        conn.logout()
        return 1

    status, _ = conn.select(f'"{folder}"')
    if status != "OK":
        print(f"ERROR: Cannot select folder '{folder}'", file=sys.stderr)
        conn.logout()
        return 1

    # Try MOVE extension first (RFC 6851), fall back to COPY+DELETE
    try:
        # Check if server supports MOVE
        if b"MOVE" in conn.capabilities or b"move" in conn.capabilities:
            status, data = conn.uid("MOVE", uid, f'"{dest}"')
        else:
            # Copy then mark deleted
            status, data = conn.uid("COPY", uid, f'"{dest}"')
            if status == "OK":
                conn.uid("STORE", uid, "+FLAGS", "(\\Deleted)")
                conn.expunge()
    except imaplib.IMAP4.error as exc:
        # Fallback: COPY + DELETE
        status, data = conn.uid("COPY", uid, f'"{dest}"')
        if status == "OK":
            conn.uid("STORE", uid, "+FLAGS", "(\\Deleted)")
            conn.expunge()
        else:
            print(f"ERROR: MOVE/COPY failed: {exc}", file=sys.stderr)
            conn.logout()
            return 1

    result = {
        "status": "moved",
        "uid": args.uid,
        "from_folder": folder,
        "to_folder": dest,
    }
    print(json.dumps(result, indent=2))
    conn.logout()
    return 0


def cmd_set_flag(args):
    """Set a flag (keyword) on a message by UID."""
    conn = connect(args.host, args.port, args.user, args.security)
    folder = args.folder or "INBOX"
    uid = str(args.uid)
    flag = args.flag

    if not flag:
        print("ERROR: --flag is required", file=sys.stderr)
        conn.logout()
        return 1

    # Map taxonomy name to IMAP keyword if needed
    imap_flag = FLAG_TAXONOMY.get(flag, flag)

    status, _ = conn.select(f'"{folder}"')
    if status != "OK":
        print(f"ERROR: Cannot select folder '{folder}'", file=sys.stderr)
        conn.logout()
        return 1

    status, data = conn.uid("STORE", uid, "+FLAGS", f"({imap_flag})")
    if status != "OK":
        print(f"ERROR: STORE +FLAGS failed: {data}", file=sys.stderr)
        conn.logout()
        return 1

    result = {
        "status": "flag_set",
        "uid": args.uid,
        "folder": folder,
        "flag": imap_flag,
        "taxonomy_name": flag if flag in FLAG_TAXONOMY else "",
    }
    print(json.dumps(result, indent=2))
    conn.logout()
    return 0


def cmd_clear_flag(args):
    """Clear a flag (keyword) from a message by UID."""
    conn = connect(args.host, args.port, args.user, args.security)
    folder = args.folder or "INBOX"
    uid = str(args.uid)
    flag = args.flag

    if not flag:
        print("ERROR: --flag is required", file=sys.stderr)
        conn.logout()
        return 1

    imap_flag = FLAG_TAXONOMY.get(flag, flag)

    status, _ = conn.select(f'"{folder}"')
    if status != "OK":
        print(f"ERROR: Cannot select folder '{folder}'", file=sys.stderr)
        conn.logout()
        return 1

    status, data = conn.uid("STORE", uid, "-FLAGS", f"({imap_flag})")
    if status != "OK":
        print(f"ERROR: STORE -FLAGS failed: {data}", file=sys.stderr)
        conn.logout()
        return 1

    result = {
        "status": "flag_cleared",
        "uid": args.uid,
        "folder": folder,
        "flag": imap_flag,
    }
    print(json.dumps(result, indent=2))
    conn.logout()
    return 0


def cmd_index_sync(args):
    """Sync folder headers to the local SQLite metadata index."""
    conn = connect(args.host, args.port, args.user, args.security)
    folder = args.folder or "INBOX"
    account_key = f"{args.user}@{args.host}"

    status, count_data = conn.select(f'"{folder}"', readonly=True)
    if status != "OK":
        print(f"ERROR: Cannot select folder '{folder}'", file=sys.stderr)
        conn.logout()
        return 1

    total = int(count_data[0] or b"0")
    if total == 0:
        print(json.dumps({"folder": folder, "synced": 0, "total": 0}))
        conn.logout()
        return 0

    db_conn = _init_index_db()

    if args.full:
        # Full sync: fetch all headers
        fetch_range = "1:*"
    else:
        # Incremental: find highest UID in index, fetch newer
        row = db_conn.execute(
            "SELECT MAX(uid) FROM messages WHERE account = ? AND folder = ?",
            (account_key, folder)
        ).fetchone()
        last_uid = row[0] if row and row[0] else 0
        if last_uid > 0:
            fetch_range = f"{last_uid + 1}:*"
        else:
            fetch_range = "1:*"

    status, data = conn.uid(
        "FETCH", fetch_range,
        "(UID FLAGS RFC822.SIZE BODY.PEEK[HEADER.FIELDS "
        "(Date From To Subject Message-ID)])"
    )

    synced = 0
    if status == "OK" and data:
        messages = _parse_envelope_from_fetch(data)
        for msg in messages:
            _upsert_message(db_conn, account_key, folder, msg["uid"], msg)
            synced += 1
        db_conn.commit()

    db_conn.close()

    result = {
        "folder": folder,
        "total": total,
        "synced": synced,
        "mode": "full" if args.full else "incremental",
    }
    print(json.dumps(result, indent=2))
    conn.logout()
    return 0


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------

def build_parser():
    """Build the argument parser with all subcommands."""
    parser = argparse.ArgumentParser(
        description="IMAP adapter for email mailbox operations"
    )

    # Common connection arguments
    parser.add_argument("--host", help="IMAP server hostname")
    parser.add_argument("--port", type=int, default=993, help="IMAP server port")
    parser.add_argument("--user", help="IMAP username (email address)")
    parser.add_argument("--security", default="TLS", choices=["TLS", "STARTTLS"],
                        help="Connection security (default: TLS)")
    parser.add_argument("--provider-config", help="Path to provider config JSON file")

    subparsers = parser.add_subparsers(dest="command", help="Command to execute")

    # connect
    subparsers.add_parser("connect", help="Test IMAP connectivity")

    # fetch_headers
    fh = subparsers.add_parser("fetch_headers", help="Fetch message headers")
    fh.add_argument("--folder", default="INBOX", help="Folder to fetch from")
    fh.add_argument("--limit", type=int, default=50, help="Max messages to fetch")
    fh.add_argument("--offset", type=int, default=0, help="Offset from most recent")

    # fetch_body
    fb = subparsers.add_parser("fetch_body", help="Fetch a message body by UID")
    fb.add_argument("--uid", type=int, required=True, help="Message UID")
    fb.add_argument("--folder", default="INBOX", help="Folder containing the message")

    # search
    sr = subparsers.add_parser("search", help="Search messages")
    sr.add_argument("--query", required=True, help="IMAP SEARCH criteria")
    sr.add_argument("--folder", default="INBOX", help="Folder to search")
    sr.add_argument("--limit", type=int, default=50, help="Max results")

    # list_folders
    subparsers.add_parser("list_folders", help="List all IMAP folders")

    # create_folder
    cf = subparsers.add_parser("create_folder", help="Create an IMAP folder")
    cf.add_argument("--folder", required=True, help="Folder path to create")

    # move_message
    mv = subparsers.add_parser("move_message", help="Move a message to another folder")
    mv.add_argument("--uid", type=int, required=True, help="Message UID")
    mv.add_argument("--dest", required=True, help="Destination folder")
    mv.add_argument("--folder", default="INBOX", help="Source folder")

    # set_flag
    sf = subparsers.add_parser("set_flag", help="Set a flag on a message")
    sf.add_argument("--uid", type=int, required=True, help="Message UID")
    sf.add_argument("--flag", required=True,
                    help="Flag name (taxonomy name or IMAP keyword)")
    sf.add_argument("--folder", default="INBOX", help="Folder containing the message")

    # clear_flag
    clf = subparsers.add_parser("clear_flag", help="Clear a flag from a message")
    clf.add_argument("--uid", type=int, required=True, help="Message UID")
    clf.add_argument("--flag", required=True, help="Flag name to clear")
    clf.add_argument("--folder", default="INBOX", help="Folder containing the message")

    # index_sync
    ix = subparsers.add_parser("index_sync", help="Sync folder to local index")
    ix.add_argument("--folder", default="INBOX", help="Folder to sync")
    ix.add_argument("--full", action="store_true", help="Full sync (not incremental)")

    return parser


def main():
    """Entry point."""
    parser = build_parser()
    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return 1

    # Validate required connection args for commands that need them
    if args.command != "help":
        if not args.host or not args.user:
            print("ERROR: --host and --user are required", file=sys.stderr)
            return 1

    commands = {
        "connect": cmd_connect,
        "fetch_headers": cmd_fetch_headers,
        "fetch_body": cmd_fetch_body,
        "search": cmd_search,
        "list_folders": cmd_list_folders,
        "create_folder": cmd_create_folder,
        "move_message": cmd_move_message,
        "set_flag": cmd_set_flag,
        "clear_flag": cmd_clear_flag,
        "index_sync": cmd_index_sync,
    }

    handler = commands.get(args.command)
    if handler:
        return handler(args)

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main() or 0)
