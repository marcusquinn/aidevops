#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
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
import email.policy
import imaplib
import json
import os
import sys
from contextlib import contextmanager

from _email_imap_index import (
    incremental_fetch_range,
    init_index_db,
    sync_messages_to_db,
    upsert_messages_to_index,
)
from _email_imap_parser import (
    extract_message_bodies,
    parse_envelope_from_fetch,
    parse_folder_entry,
)


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Custom flag taxonomy mapping (from email-mailbox.md)
FLAG_TAXONOMY = {
    "Reminders": "$Reminder",
    "Tasks": "$Task",
    "Review": "$Review",
    "Filing": "$Filing",
    "Ideas": "$Idea",
    "Add-to-Contacts": "$AddContact",
}


class IMAPError(Exception):
    """IMAP operation failed (folder select, fetch, etc.)."""


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
    except Exception as exc:
        print(f"ERROR: IMAP connection failed: {exc}", file=sys.stderr)
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


@contextmanager
def _imap_connection(args):
    """Context manager for IMAP connection with auto-logout."""
    conn = connect(args.host, args.port, args.user, args.security)
    try:
        yield conn
    finally:
        conn.logout()


def _select_folder_or_fail(conn, folder, readonly=True):
    """Select an IMAP folder, raising IMAPError on failure.

    Returns the total message count in the folder.
    """
    status, count_data = conn.select(f'"{folder}"', readonly=readonly)
    if status != "OK":
        raise IMAPError(f"Cannot select folder '{folder}'")
    return int(count_data[0] or b"0")


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_connect(args):
    """Test IMAP connectivity and report server capabilities."""
    with _imap_connection(args) as conn:
        caps = conn.capabilities
        cap_list = [c.decode("utf-8") if isinstance(c, bytes) else str(c) for c in caps]

        result = {
            "status": "connected",
            "host": args.host,
            "port": args.port,
            "user": args.user,
            "capabilities": cap_list,
        }
        print(json.dumps(result, indent=2))
        return 0


def cmd_fetch_headers(args):
    """Fetch message headers from a folder using BODY.PEEK (no read marking)."""
    folder = args.folder or "INBOX"
    limit = args.limit or 50
    offset = args.offset or 0

    with _imap_connection(args) as conn:
        total = _select_folder_or_fail(conn, folder, readonly=True)
        if total == 0:
            print(json.dumps({"folder": folder, "total": 0, "messages": []}))
            return 0

        end = max(1, total - offset)
        start = max(1, end - limit + 1)
        fetch_range = f"{start}:{end}"

        status, data = conn.fetch(
            fetch_range,
            "(UID FLAGS RFC822.SIZE BODY.PEEK[HEADER.FIELDS "
            "(Date From To Subject Message-ID In-Reply-To References)])"
        )
        if status != "OK":
            raise IMAPError(f"FETCH failed: {data}")

        messages = parse_envelope_from_fetch(data)
        messages.sort(key=lambda m: m["uid"], reverse=True)

        upsert_messages_to_index(f"{args.user}@{args.host}", folder, messages)

        result = {
            "folder": folder,
            "total": total,
            "offset": offset,
            "limit": limit,
            "returned": len(messages),
            "messages": messages,
        }
        print(json.dumps(result, indent=2))
        return 0


def cmd_fetch_body(args):
    """Fetch a single message body by UID using BODY.PEEK."""
    folder = args.folder or "INBOX"

    with _imap_connection(args) as conn:
        _select_folder_or_fail(conn, folder, readonly=True)

        # Fetch full message using BODY.PEEK (doesn't mark as read)
        status, data = conn.uid("FETCH", str(args.uid), "(BODY.PEEK[])")
        if status != "OK" or not data or data[0] is None:
            raise IMAPError(f"Message UID {args.uid} not found")

        raw_email = data[0][1] if isinstance(data[0], tuple) else b""
        msg = email.message_from_bytes(raw_email, policy=email.policy.default)

        text_body, html_body, attachments = extract_message_bodies(msg)

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
        return 0


def cmd_search(args):
    """Search messages using IMAP SEARCH criteria."""
    folder = args.folder or "INBOX"
    criteria = args.query
    if not criteria:
        print("ERROR: --query is required for search", file=sys.stderr)
        return 1

    with _imap_connection(args) as conn:
        _select_folder_or_fail(conn, folder, readonly=True)

        status, data = conn.uid("SEARCH", "CHARSET", "UTF-8", criteria)
        if status != "OK":
            raise IMAPError(f"SEARCH failed: {data}")

        uid_list = data[0].split() if data[0] else []
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
                messages = parse_envelope_from_fetch(fetch_data)
                messages.sort(key=lambda m: m["uid"], reverse=True)

        result = {
            "folder": folder,
            "query": criteria,
            "total_matches": len(uid_list),
            "returned": len(messages),
            "messages": messages,
        }
        print(json.dumps(result, indent=2))
        return 0


def cmd_list_folders(args):
    """List all IMAP folders with provider-aware name mapping."""
    with _imap_connection(args) as conn:
        status, folder_data = conn.list()
        if status != "OK":
            raise IMAPError("LIST failed")

        provider_config = _parse_provider_config(args.provider_config)
        folder_mapping = _get_folder_mapping(provider_config)
        reverse_mapping = {v: k for k, v in folder_mapping.items()}

        folders = [
            entry for item in folder_data
            if (entry := parse_folder_entry(item, reverse_mapping)) is not None
        ]

        result = {
            "total": len(folders),
            "folder_mapping": folder_mapping,
            "folders": folders,
        }
        print(json.dumps(result, indent=2))
        return 0


def cmd_create_folder(args):
    """Create an IMAP folder (mailbox)."""
    folder = args.folder
    if not folder:
        print("ERROR: --folder is required", file=sys.stderr)
        return 1

    with _imap_connection(args) as conn:
        status, data = conn.create(f'"{folder}"')
        if status != "OK":
            raise IMAPError(f"CREATE failed: {data}")

        conn.subscribe(f'"{folder}"')

        result = {"status": "created", "folder": folder}
        print(json.dumps(result, indent=2))
        return 0


def _copy_and_delete(conn, uid, dest):
    """Copy a message to dest and mark the original as deleted."""
    status, data = conn.uid("COPY", uid, f'"{dest}"')
    if status == "OK":
        conn.uid("STORE", uid, "+FLAGS", "(\\Deleted)")
        conn.expunge()
    return status, data


def _imap_move(conn, uid, dest):
    """Move a message using MOVE extension or COPY+DELETE fallback.

    Returns (status, data) from the final operation.
    """
    has_move = b"MOVE" in conn.capabilities or b"move" in conn.capabilities
    if has_move:
        try:
            return conn.uid("MOVE", uid, f'"{dest}"')
        except imaplib.IMAP4.error:
            pass  # MOVE not supported despite capability; fall through
    return _copy_and_delete(conn, uid, dest)


def cmd_move_message(args):
    """Move a message to a destination folder by UID."""
    folder = args.folder or "INBOX"
    dest = args.dest
    uid = str(args.uid)

    if not dest:
        print("ERROR: --dest is required", file=sys.stderr)
        return 1

    with _imap_connection(args) as conn:
        _select_folder_or_fail(conn, folder, readonly=False)

        status, _data = _imap_move(conn, uid, dest)
        if status != "OK":
            raise IMAPError(f"MOVE failed for UID {args.uid}")

        result = {
            "status": "moved",
            "uid": args.uid,
            "from_folder": folder,
            "to_folder": dest,
        }
        print(json.dumps(result, indent=2))
        return 0


def _cmd_modify_flag(args, add=True):
    """Set or clear a flag (keyword) on a message by UID.

    Args:
        args: Parsed CLI arguments (uid, flag, folder, connection params).
        add: True to add the flag (+FLAGS), False to remove (-FLAGS).
    """
    folder = args.folder or "INBOX"
    uid = str(args.uid)
    flag = args.flag

    if not flag:
        print("ERROR: --flag is required", file=sys.stderr)
        return 1

    imap_flag = FLAG_TAXONOMY.get(flag, flag)
    operation = "+FLAGS" if add else "-FLAGS"

    with _imap_connection(args) as conn:
        _select_folder_or_fail(conn, folder, readonly=False)

        status, data = conn.uid("STORE", uid, operation, f"({imap_flag})")
        if status != "OK":
            raise IMAPError(f"STORE {operation} failed: {data}")

        result = {
            "status": "flag_set" if add else "flag_cleared",
            "uid": args.uid,
            "folder": folder,
            "flag": imap_flag,
            "taxonomy_name": flag if flag in FLAG_TAXONOMY else "",
        }
        print(json.dumps(result, indent=2))
        return 0


def cmd_set_flag(args):
    """Set a flag (keyword) on a message by UID."""
    return _cmd_modify_flag(args, add=True)


def cmd_clear_flag(args):
    """Clear a flag (keyword) from a message by UID."""
    return _cmd_modify_flag(args, add=False)


def cmd_index_sync(args):
    """Sync folder headers to the local SQLite metadata index."""
    folder = args.folder or "INBOX"
    account_key = f"{args.user}@{args.host}"

    with _imap_connection(args) as conn:
        total = _select_folder_or_fail(conn, folder, readonly=True)
        if total == 0:
            print(json.dumps({"folder": folder, "synced": 0, "total": 0}))
            return 0

        db_conn = init_index_db()
        fetch_range = "1:*" if args.full else incremental_fetch_range(db_conn, account_key, folder)

        status, data = conn.uid(
            "FETCH", fetch_range,
            "(UID FLAGS RFC822.SIZE BODY.PEEK[HEADER.FIELDS "
            "(Date From To Subject Message-ID)])"
        )

        synced = sync_messages_to_db(
            db_conn, account_key, folder, data, parse_envelope_from_fetch
        ) if (status == "OK" and data) else 0
        db_conn.close()

        result = {
            "folder": folder,
            "total": total,
            "synced": synced,
            "mode": "full" if args.full else "incremental",
        }
        print(json.dumps(result, indent=2))
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
    if not handler:
        parser.print_help()
        return 1

    try:
        return handler(args)
    except IMAPError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main() or 0)
