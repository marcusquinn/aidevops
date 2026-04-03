#!/usr/bin/env python3
"""
email_jmap_adapter.py - JMAP adapter for mailbox operations (RFC 8620/8621).

Provides JMAP connection, header fetching, body fetching, search, move,
flag, and push notification operations. Designed for Fastmail and other
JMAP-compatible providers (Cyrus 3.x, Apache James, Stalwart).

Part of the email mailbox helper (t1525). Called by email-mailbox-helper.sh.

Usage:
    python3 email_jmap_adapter.py connect --session-url URL --user USER
    python3 email_jmap_adapter.py fetch_headers --mailbox INBOX [--limit 50] [--position 0]
    python3 email_jmap_adapter.py fetch_body --email-id ID
    python3 email_jmap_adapter.py search --filter '{"from":"sender@example.com"}' [--mailbox INBOX]
    python3 email_jmap_adapter.py list_mailboxes
    python3 email_jmap_adapter.py create_mailbox --name "Archive/Projects/acme"
    python3 email_jmap_adapter.py move_email --email-id ID --dest-mailbox "Archive"
    python3 email_jmap_adapter.py set_keyword --email-id ID --keyword "$Task"
    python3 email_jmap_adapter.py clear_keyword --email-id ID --keyword "$Task"
    python3 email_jmap_adapter.py index_sync --mailbox INBOX [--full]
    python3 email_jmap_adapter.py push --types mail [--timeout 300]

Credentials: read from JMAP_TOKEN environment variable (never from argv).
    For Fastmail: use an app-specific password or API token.
    For basic auth: set JMAP_PASSWORD instead (used with --user for HTTP Basic).

Output: JSON to stdout. Errors to stderr.
"""

import argparse
import json
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

INDEX_DIR = Path.home() / ".aidevops" / ".agent-workspace" / "email-mailbox"
INDEX_DB = INDEX_DIR / "index.db"

# Custom keyword taxonomy mapping (from email-mailbox.md)
# JMAP uses keywords directly — no PERMANENTFLAGS limitation like IMAP
KEYWORD_TAXONOMY = {
    "Reminders": "$reminder",
    "Tasks": "$task",
    "Review": "$review",
    "Filing": "$filing",
    "Ideas": "$idea",
    "Add-to-Contacts": "$addcontact",
}

# Standard JMAP keywords (RFC 8621 Section 2.1)
STANDARD_KEYWORDS = {
    "$seen": "Message has been read",
    "$flagged": "Message is flagged/starred",
    "$answered": "Message has been replied to",
    "$draft": "Message is a draft",
    "$forwarded": "Message has been forwarded",
}

# Default JMAP properties to fetch for headers
HEADER_PROPERTIES = [
    "id", "blobId", "threadId", "mailboxIds",
    "from", "to", "subject", "receivedAt",
    "sentAt", "size", "keywords", "messageId",
    "inReplyTo", "references", "preview",
]

# Full body properties
BODY_PROPERTIES = HEADER_PROPERTIES + [
    "cc", "bcc", "replyTo", "textBody", "htmlBody",
    "attachments", "bodyValues", "hasAttachment",
]

_SYNC_STATE_UPSERT = (
    "INSERT INTO jmap_sync_state (account, mailbox_id, state) "
    "VALUES (?, ?, ?) "
    "ON CONFLICT (account, mailbox_id) DO UPDATE SET "
    "state = excluded.state, "
    "updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')"
)


# ---------------------------------------------------------------------------
# SQLite metadata index (shared with IMAP adapter)
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


# ---------------------------------------------------------------------------
# JMAP HTTP transport
# ---------------------------------------------------------------------------

def _get_auth():
    """Get authentication credentials from environment variables.

    Returns:
        tuple: (auth_type, credential) where auth_type is 'bearer' or 'basic'.
    """
    token = os.environ.get("JMAP_TOKEN", "")
    if token:
        return ("bearer", token)

    password = os.environ.get("JMAP_PASSWORD", "")
    if password:
        return ("basic", password)

    print(
        "ERROR: JMAP_TOKEN or JMAP_PASSWORD environment variable not set",
        file=sys.stderr,
    )
    print(
        "Set via: JMAP_TOKEN=$(gopass show -o email-jmap-account) python3 ...",
        file=sys.stderr,
    )
    sys.exit(1)


def _make_auth_header(user, auth_type, credential):
    """Build the Authorization header value."""
    if auth_type == "bearer":
        return "Bearer " + credential
    # Basic auth
    import base64  # pylint: disable=import-outside-toplevel
    pair = user + ":" + credential
    encoded = base64.b64encode(pair.encode("utf-8")).decode("ascii")
    return "Basic " + encoded


def _jmap_request(api_url, user, method_calls, using=None):
    """Send a JMAP request and return the response.

    Args:
        api_url: The JMAP API endpoint URL.
        user: Username for authentication.
        method_calls: List of JMAP method call triples [name, args, call_id].
        using: List of JMAP capability URIs. Defaults to core + mail.

    Returns:
        dict: Parsed JSON response.
    """
    if using is None:
        using = [
            "urn:ietf:params:jmap:core",
            "urn:ietf:params:jmap:mail",
        ]

    auth_type, credential = _get_auth()
    auth_header = _make_auth_header(user, auth_type, credential)

    request_body = {
        "using": using,
        "methodCalls": method_calls,
    }

    data = json.dumps(request_body).encode("utf-8")
    req = urllib.request.Request(
        api_url,
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": auth_header,
            "Accept": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = ""
        try:
            body = exc.read().decode("utf-8", errors="replace")
        except Exception:  # pylint: disable=broad-exception-caught
            pass
        print(
            f"ERROR: JMAP request failed (HTTP {exc.code}): {body}",
            file=sys.stderr,
        )
        sys.exit(1)
    except urllib.error.URLError as exc:
        print(f"ERROR: JMAP connection failed: {exc.reason}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:  # pylint: disable=broad-exception-caught
        print(f"ERROR: JMAP request error: {exc}", file=sys.stderr)
        sys.exit(1)


def _get_session(session_url, user):
    """Fetch the JMAP session resource (RFC 8620 Section 2).

    Returns:
        dict: Session object with accounts, capabilities, apiUrl, etc.
    """
    auth_type, credential = _get_auth()
    auth_header = _make_auth_header(user, auth_type, credential)

    req = urllib.request.Request(
        session_url,
        headers={
            "Authorization": auth_header,
            "Accept": "application/json",
        },
        method="GET",
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = ""
        try:
            body = exc.read().decode("utf-8", errors="replace")
        except Exception:  # pylint: disable=broad-exception-caught
            pass
        print(
            f"ERROR: JMAP session fetch failed (HTTP {exc.code}): {body}",
            file=sys.stderr,
        )
        sys.exit(1)
    except Exception as exc:  # pylint: disable=broad-exception-caught
        print(f"ERROR: JMAP session error: {exc}", file=sys.stderr)
        sys.exit(1)


def _get_primary_account(session):
    """Extract the primary mail account ID from a JMAP session."""
    primary = session.get("primaryAccounts", {})
    account_id = primary.get("urn:ietf:params:jmap:mail", "")
    if not account_id:
        # Fallback: first account with mail capability
        for acct_id, acct in session.get("accounts", {}).items():
            caps = acct.get("accountCapabilities", {})
            if "urn:ietf:params:jmap:mail" in caps:
                return acct_id
        print("ERROR: No mail-capable account found in JMAP session", file=sys.stderr)
        sys.exit(1)
    return account_id


def _session_context(args):
    """Fetch session and return (session, account_id, api_url) tuple."""
    session = _get_session(args.session_url, args.user)
    account_id = _get_primary_account(session)
    api_url = session.get("apiUrl", "")
    return session, account_id, api_url


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_connect(args):
    """Test JMAP connectivity and report session capabilities."""
    session, account_id, _ = _session_context(args)
    account_info = session.get("accounts", {}).get(account_id, {})

    capabilities = list(session.get("capabilities", {}).keys())
    account_capabilities = list(
        account_info.get("accountCapabilities", {}).keys()
    )

    result = {
        "status": "connected",
        "session_url": args.session_url,
        "api_url": session.get("apiUrl", ""),
        "upload_url": session.get("uploadUrl", ""),
        "download_url": session.get("downloadUrl", ""),
        "event_source_url": session.get("eventSourceUrl", ""),
        "user": args.user,
        "account_id": account_id,
        "account_name": account_info.get("name", ""),
        "capabilities": capabilities,
        "account_capabilities": account_capabilities,
        "state": session.get("state", ""),
    }
    print(json.dumps(result, indent=2))
    return 0


def cmd_fetch_headers(args):
    """Fetch email headers from a mailbox using Email/query + Email/get."""
    _, account_id, api_url = _session_context(args)

    # Resolve mailbox name to ID
    mailbox_name = args.mailbox or "INBOX"
    mailbox_id = _resolve_mailbox_id(
        api_url, args.user, account_id, mailbox_name
    )
    if not mailbox_id:
        print(
            f"ERROR: Mailbox '{mailbox_name}' not found",
            file=sys.stderr,
        )
        return 1

    limit = args.limit or 50
    position = args.position or 0

    # Email/query to get IDs sorted by receivedAt descending
    method_calls = [
        [
            "Email/query",
            {
                "accountId": account_id,
                "filter": {"inMailbox": mailbox_id},
                "sort": [{"property": "receivedAt", "isAscending": False}],
                "position": position,
                "limit": limit,
            },
            "q0",
        ],
        [
            "Email/get",
            {
                "accountId": account_id,
                "#ids": {
                    "resultOf": "q0",
                    "name": "Email/query",
                    "path": "/ids",
                },
                "properties": HEADER_PROPERTIES,
            },
            "g0",
        ],
    ]

    response = _jmap_request(api_url, args.user, method_calls)
    method_responses = response.get("methodResponses", [])

    query_result = _find_response(method_responses, "Email/query", "q0")
    get_result = _find_response(method_responses, "Email/get", "g0")

    if not query_result or not get_result:
        print("ERROR: Unexpected JMAP response structure", file=sys.stderr)
        return 1

    total = query_result.get("total", 0)
    emails = get_result.get("list", [])

    # Format for output (match IMAP adapter structure where practical)
    messages = [_format_email_header(em) for em in emails]

    # Update SQLite index
    account_key = f"{args.user}@jmap"
    db_conn = _init_index_db()
    for em in emails:
        _upsert_jmap_email(db_conn, account_key, em)
    db_conn.commit()
    db_conn.close()

    result = {
        "mailbox": mailbox_name,
        "mailbox_id": mailbox_id,
        "total": total,
        "position": position,
        "limit": limit,
        "returned": len(messages),
        "messages": messages,
    }
    print(json.dumps(result, indent=2))
    return 0


def _extract_text_body(em, body_values):
    """Extract concatenated text body from email parts."""
    text_body = ""
    for part in em.get("textBody") or []:
        part_id = part.get("partId", "")
        if part_id in body_values:
            text_body += body_values[part_id].get("value", "")
    return text_body


def _extract_html_body_length(em, body_values):
    """Return total byte length of HTML body parts."""
    length = 0
    for part in em.get("htmlBody") or []:
        part_id = part.get("partId", "")
        if part_id in body_values:
            length += len(body_values[part_id].get("value", ""))
    return length


def _extract_attachments(em):
    """Return a list of attachment summary dicts."""
    return [
        {
            "filename": att.get("name") or "unnamed",
            "content_type": att.get("type", ""),
            "size": att.get("size", 0),
            "blob_id": att.get("blobId", ""),
        }
        for att in em.get("attachments") or []
    ]


def cmd_fetch_body(args):
    """Fetch a single email body by JMAP email ID."""
    _, account_id, api_url = _session_context(args)

    method_calls = [
        [
            "Email/get",
            {
                "accountId": account_id,
                "ids": [args.email_id],
                "properties": BODY_PROPERTIES,
                "fetchTextBodyValues": True,
                "fetchHTMLBodyValues": True,
                "maxBodyValueBytes": 1048576,  # 1MB
            },
            "g0",
        ],
    ]

    response = _jmap_request(api_url, args.user, method_calls)
    get_result = _find_response(
        response.get("methodResponses", []), "Email/get", "g0"
    )

    if not get_result:
        print("ERROR: Unexpected JMAP response", file=sys.stderr)
        return 1

    emails = get_result.get("list", [])
    if not emails:
        not_found = get_result.get("notFound", [])
        if args.email_id in not_found:
            print(
                f"ERROR: Email ID '{args.email_id}' not found",
                file=sys.stderr,
            )
        else:
            print("ERROR: No email returned", file=sys.stderr)
        return 1

    em = emails[0]
    body_values = em.get("bodyValues", {})

    from_addrs = em.get("from") or []
    to_addrs = em.get("to") or []
    cc_addrs = em.get("cc") or []

    result = {
        "email_id": em.get("id", ""),
        "thread_id": em.get("threadId", ""),
        "blob_id": em.get("blobId", ""),
        "mailbox_ids": list((em.get("mailboxIds") or {}).keys()),
        "message_id": _first_or_empty(em.get("messageId")),
        "date": em.get("receivedAt", ""),
        "sent_at": em.get("sentAt", ""),
        "from": _format_addresses(from_addrs),
        "to": _format_addresses(to_addrs),
        "cc": _format_addresses(cc_addrs),
        "subject": em.get("subject", ""),
        "in_reply_to": _first_or_empty(em.get("inReplyTo")),
        "references": em.get("references") or [],
        "keywords": list((em.get("keywords") or {}).keys()),
        "text_body": _extract_text_body(em, body_values),
        "html_body_length": _extract_html_body_length(em, body_values),
        "has_attachment": em.get("hasAttachment", False),
        "attachments": _extract_attachments(em),
        "preview": em.get("preview", ""),
    }
    print(json.dumps(result, indent=2))
    return 0


def _build_search_filter(args, api_url, account_id):
    """Parse and optionally scope a search filter to a mailbox."""
    try:
        filter_obj = json.loads(args.filter)
    except (json.JSONDecodeError, TypeError):
        filter_obj = {"text": args.filter}

    if not args.mailbox:
        return filter_obj

    mailbox_id = _resolve_mailbox_id(
        api_url, args.user, account_id, args.mailbox
    )
    if not mailbox_id:
        return filter_obj

    if "operator" in filter_obj:
        return {
            "operator": "AND",
            "conditions": [{"inMailbox": mailbox_id}, filter_obj],
        }
    filter_obj["inMailbox"] = mailbox_id
    return filter_obj


def cmd_search(args):
    """Search emails using JMAP Email/query with FilterCondition."""
    _, account_id, api_url = _session_context(args)

    filter_obj = _build_search_filter(args, api_url, account_id)
    limit = args.limit or 50

    method_calls = [
        [
            "Email/query",
            {
                "accountId": account_id,
                "filter": filter_obj,
                "sort": [{"property": "receivedAt", "isAscending": False}],
                "limit": limit,
            },
            "q0",
        ],
        [
            "Email/get",
            {
                "accountId": account_id,
                "#ids": {
                    "resultOf": "q0",
                    "name": "Email/query",
                    "path": "/ids",
                },
                "properties": HEADER_PROPERTIES,
            },
            "g0",
        ],
    ]

    response = _jmap_request(api_url, args.user, method_calls)
    method_responses = response.get("methodResponses", [])

    query_result = _find_response(method_responses, "Email/query", "q0")
    get_result = _find_response(method_responses, "Email/get", "g0")

    if not query_result or not get_result:
        print("ERROR: Unexpected JMAP response", file=sys.stderr)
        return 1

    emails = get_result.get("list", [])
    messages = [_format_email_header(em) for em in emails]

    result = {
        "mailbox": args.mailbox or "(all)",
        "filter": filter_obj,
        "total_matches": query_result.get("total", 0),
        "returned": len(messages),
        "messages": messages,
    }
    print(json.dumps(result, indent=2))
    return 0


def cmd_list_mailboxes(args):
    """List all JMAP mailboxes with hierarchy."""
    _, account_id, api_url = _session_context(args)

    method_calls = [
        [
            "Mailbox/get",
            {
                "accountId": account_id,
                "properties": [
                    "id", "name", "parentId", "role",
                    "totalEmails", "unreadEmails", "sortOrder",
                    "myRights",
                ],
            },
            "m0",
        ],
    ]

    response = _jmap_request(api_url, args.user, method_calls)
    get_result = _find_response(
        response.get("methodResponses", []), "Mailbox/get", "m0"
    )

    if not get_result:
        print("ERROR: Unexpected JMAP response", file=sys.stderr)
        return 1

    mailboxes_raw = get_result.get("list", [])

    # Build hierarchy paths
    id_to_mailbox = {mb["id"]: mb for mb in mailboxes_raw}
    mailboxes = []
    for mb in mailboxes_raw:
        path = _build_mailbox_path(mb, id_to_mailbox)
        mailboxes.append({
            "id": mb.get("id", ""),
            "name": mb.get("name", ""),
            "path": path,
            "role": mb.get("role") or "",
            "parent_id": mb.get("parentId") or "",
            "total_emails": mb.get("totalEmails", 0),
            "unread_emails": mb.get("unreadEmails", 0),
            "sort_order": mb.get("sortOrder", 0),
        })

    # Sort by path for readable output
    mailboxes.sort(key=lambda m: m["path"])

    result = {
        "total": len(mailboxes),
        "mailboxes": mailboxes,
    }
    print(json.dumps(result, indent=2))
    return 0


def cmd_create_mailbox(args):
    """Create a JMAP mailbox, including nested paths."""
    _, account_id, api_url = _session_context(args)

    name = args.name
    if not name:
        print("ERROR: --name is required", file=sys.stderr)
        return 1

    # Handle nested paths (e.g., "Archive/Projects/acme")
    parts = name.split("/")
    parent_id = None

    if len(parts) > 1:
        # Resolve parent path
        parent_path = "/".join(parts[:-1])
        parent_id = _resolve_mailbox_id(
            api_url, args.user, account_id, parent_path
        )
        if not parent_id:
            print(
                f"ERROR: Parent mailbox '{parent_path}' not found. "
                "Create parent mailboxes first.",
                file=sys.stderr,
            )
            return 1

    create_args = {
        "accountId": account_id,
        "create": {
            "new0": {
                "name": parts[-1],
            },
        },
    }
    if parent_id:
        create_args["create"]["new0"]["parentId"] = parent_id

    method_calls = [["Mailbox/set", create_args, "c0"]]

    response = _jmap_request(api_url, args.user, method_calls)
    set_result = _find_response(
        response.get("methodResponses", []), "Mailbox/set", "c0"
    )

    if not set_result:
        print("ERROR: Unexpected JMAP response", file=sys.stderr)
        return 1

    created = set_result.get("created", {})
    not_created = set_result.get("notCreated", {})

    if "new0" in created:
        result = {
            "status": "created",
            "mailbox": name,
            "id": created["new0"].get("id", ""),
        }
        print(json.dumps(result, indent=2))
        return 0

    if "new0" in not_created:
        err = not_created["new0"]
        print(
            f"ERROR: Mailbox creation failed: {err.get('description', err)}",
            file=sys.stderr,
        )
        return 1

    print("ERROR: Unknown creation result", file=sys.stderr)
    return 1


def _fetch_email_mailbox_ids(api_url, user, account_id, email_id):
    """Return current mailboxIds dict for an email, or None on error."""
    get_calls = [
        [
            "Email/get",
            {
                "accountId": account_id,
                "ids": [email_id],
                "properties": ["mailboxIds"],
            },
            "g0",
        ],
    ]
    get_response = _jmap_request(api_url, user, get_calls)
    get_result = _find_response(
        get_response.get("methodResponses", []), "Email/get", "g0"
    )
    if not get_result or not get_result.get("list"):
        return None
    return get_result["list"][0].get("mailboxIds", {})


def cmd_move_email(args):
    """Move an email to a different mailbox by updating mailboxIds."""
    _, account_id, api_url = _session_context(args)

    dest_name = args.dest_mailbox
    if not dest_name:
        print("ERROR: --dest-mailbox is required", file=sys.stderr)
        return 1

    dest_id = _resolve_mailbox_id(
        api_url, args.user, account_id, dest_name
    )
    if not dest_id:
        print(
            f"ERROR: Destination mailbox '{dest_name}' not found",
            file=sys.stderr,
        )
        return 1

    current_mailboxes = _fetch_email_mailbox_ids(
        api_url, args.user, account_id, args.email_id
    )
    if current_mailboxes is None:
        print(
            f"ERROR: Email '{args.email_id}' not found",
            file=sys.stderr,
        )
        return 1

    # Build update: remove from all current mailboxes, add to destination
    update_patch = {f"mailboxIds/{mb_id}": None for mb_id in current_mailboxes}
    update_patch[f"mailboxIds/{dest_id}"] = True

    set_calls = [
        [
            "Email/set",
            {
                "accountId": account_id,
                "update": {args.email_id: update_patch},
            },
            "s0",
        ],
    ]

    set_response = _jmap_request(api_url, args.user, set_calls)
    set_result = _find_response(
        set_response.get("methodResponses", []), "Email/set", "s0"
    )

    if not set_result:
        print("ERROR: Unexpected JMAP response", file=sys.stderr)
        return 1

    not_updated = set_result.get("notUpdated", {})
    if args.email_id in not_updated:
        err = not_updated[args.email_id]
        print(
            f"ERROR: Move failed: {err.get('description', err)}",
            file=sys.stderr,
        )
        return 1

    result = {
        "status": "moved",
        "email_id": args.email_id,
        "from_mailboxes": list(current_mailboxes.keys()),
        "to_mailbox": dest_name,
        "to_mailbox_id": dest_id,
    }
    print(json.dumps(result, indent=2))
    return 0


def _apply_keyword_update(api_url, user, account_id, email_id, patch):
    """Send an Email/set keyword patch and return (set_result, error_msg)."""
    method_calls = [
        [
            "Email/set",
            {
                "accountId": account_id,
                "update": {email_id: patch},
            },
            "s0",
        ],
    ]
    response = _jmap_request(api_url, user, method_calls)
    set_result = _find_response(
        response.get("methodResponses", []), "Email/set", "s0"
    )
    return set_result


def cmd_set_keyword(args):
    """Set a keyword on an email."""
    _, account_id, api_url = _session_context(args)

    keyword = args.keyword
    if not keyword:
        print("ERROR: --keyword is required", file=sys.stderr)
        return 1

    # Map taxonomy name to JMAP keyword if needed
    jmap_keyword = KEYWORD_TAXONOMY.get(keyword, keyword)
    set_result = _apply_keyword_update(
        api_url, args.user, account_id, args.email_id,
        {f"keywords/{jmap_keyword}": True},
    )

    if not set_result:
        print("ERROR: Unexpected JMAP response", file=sys.stderr)
        return 1

    not_updated = set_result.get("notUpdated", {})
    if args.email_id in not_updated:
        err = not_updated[args.email_id]
        print(
            f"ERROR: Set keyword failed: {err.get('description', err)}",
            file=sys.stderr,
        )
        return 1

    result = {
        "status": "keyword_set",
        "email_id": args.email_id,
        "keyword": jmap_keyword,
        "taxonomy_name": keyword if keyword in KEYWORD_TAXONOMY else "",
    }
    print(json.dumps(result, indent=2))
    return 0


def cmd_clear_keyword(args):
    """Clear a keyword from an email."""
    _, account_id, api_url = _session_context(args)

    keyword = args.keyword
    if not keyword:
        print("ERROR: --keyword is required", file=sys.stderr)
        return 1

    jmap_keyword = KEYWORD_TAXONOMY.get(keyword, keyword)
    set_result = _apply_keyword_update(
        api_url, args.user, account_id, args.email_id,
        {f"keywords/{jmap_keyword}": None},
    )

    if not set_result:
        print("ERROR: Unexpected JMAP response", file=sys.stderr)
        return 1

    not_updated = set_result.get("notUpdated", {})
    if args.email_id in not_updated:
        err = not_updated[args.email_id]
        print(
            f"ERROR: Clear keyword failed: {err.get('description', err)}",
            file=sys.stderr,
        )
        return 1

    result = {
        "status": "keyword_cleared",
        "email_id": args.email_id,
        "keyword": jmap_keyword,
    }
    print(json.dumps(result, indent=2))
    return 0


# ---------------------------------------------------------------------------
# index_sync helpers
# ---------------------------------------------------------------------------

def _load_saved_sync_state(db_conn, account_key, mailbox_id):
    """Return the saved JMAP query state string, or None."""
    row = db_conn.execute(
        "SELECT state FROM jmap_sync_state "
        "WHERE account = ? AND mailbox_id = ?",
        (account_key, mailbox_id),
    ).fetchone()
    return row[0] if row else None


def _save_sync_state(db_conn, account_key, mailbox_id, state):
    """Persist a JMAP query/sync state string."""
    db_conn.execute(_SYNC_STATE_UPSERT, (account_key, mailbox_id, state))


def _fetch_email_headers_batch(api_url, user, account_id, email_ids):
    """Fetch header properties for a list of email IDs. Returns list or []."""
    get_calls = [
        [
            "Email/get",
            {
                "accountId": account_id,
                "ids": email_ids,
                "properties": HEADER_PROPERTIES,
            },
            "g0",
        ],
    ]
    get_response = _jmap_request(api_url, user, get_calls)
    get_result = _find_response(
        get_response.get("methodResponses", []), "Email/get", "g0"
    )
    return get_result.get("list", []) if get_result else []


def _delta_sync(api_url, user, account_id, account_key, mailbox_id,
                saved_state, db_conn):
    """Attempt delta sync using Email/queryChanges.

    Returns (synced_count, removed_count, new_state) on success,
    or raises Exception to signal fallback to full sync.
    """
    method_calls = [
        [
            "Email/queryChanges",
            {
                "accountId": account_id,
                "filter": {"inMailbox": mailbox_id},
                "sort": [{"property": "receivedAt", "isAscending": False}],
                "sinceQueryState": saved_state,
            },
            "qc0",
        ],
    ]

    response = _jmap_request(api_url, user, method_calls)
    qc_result = _find_response(
        response.get("methodResponses", []), "Email/queryChanges", "qc0"
    )

    if not qc_result or "added" not in qc_result:
        raise ValueError("No queryChanges result")

    added_ids = [item["id"] for item in qc_result.get("added", [])]
    new_state = qc_result.get("newQueryState", "")
    removed_ids = qc_result.get("removed", [])

    synced = 0
    if added_ids:
        emails = _fetch_email_headers_batch(api_url, user, account_id, added_ids)
        for em in emails:
            _upsert_jmap_email(db_conn, account_key, em)
            synced += 1

    for rid in removed_ids:
        db_conn.execute(
            "DELETE FROM jmap_emails WHERE account = ? AND email_id = ?",
            (account_key, rid),
        )

    if new_state:
        _save_sync_state(db_conn, account_key, mailbox_id, new_state)

    db_conn.commit()
    return synced, len(removed_ids), new_state


def _query_all_email_ids(api_url, user, account_id, mailbox_id, batch_size=100):
    """Page through Email/query to collect all email IDs in a mailbox.

    Returns (all_ids, query_state).
    """
    all_ids = []
    position = 0
    query_state = ""

    while True:
        method_calls = [
            [
                "Email/query",
                {
                    "accountId": account_id,
                    "filter": {"inMailbox": mailbox_id},
                    "sort": [{"property": "receivedAt", "isAscending": False}],
                    "position": position,
                    "limit": batch_size,
                },
                "q0",
            ],
        ]

        response = _jmap_request(api_url, user, method_calls)
        query_result = _find_response(
            response.get("methodResponses", []), "Email/query", "q0"
        )

        if not query_result:
            break

        ids = query_result.get("ids", [])
        if not ids:
            break

        if position == 0:
            query_state = query_result.get("queryState", "")

        all_ids.extend(ids)
        position += len(ids)

        if position >= query_result.get("total", 0):
            break

    return all_ids, query_state


def _full_sync(api_url, user, account_id, account_key, mailbox_id, db_conn):
    """Full sync: fetch all email IDs then retrieve headers in batches.

    Returns (synced_count, query_state).
    """
    batch_size = 100
    all_ids, query_state = _query_all_email_ids(
        api_url, user, account_id, mailbox_id, batch_size
    )

    synced = 0
    for i in range(0, len(all_ids), batch_size):
        batch_ids = all_ids[i: i + batch_size]
        emails = _fetch_email_headers_batch(api_url, user, account_id, batch_ids)
        for em in emails:
            _upsert_jmap_email(db_conn, account_key, em)
            synced += 1

    if query_state:
        _save_sync_state(db_conn, account_key, mailbox_id, query_state)

    db_conn.commit()
    return synced, query_state


def cmd_index_sync(args):
    """Sync mailbox headers to the local SQLite metadata index.

    Uses JMAP state strings for efficient delta sync when available.
    """
    _, account_id, api_url = _session_context(args)

    mailbox_name = args.mailbox or "INBOX"
    mailbox_id = _resolve_mailbox_id(
        api_url, args.user, account_id, mailbox_name
    )
    if not mailbox_id:
        print(
            f"ERROR: Mailbox '{mailbox_name}' not found",
            file=sys.stderr,
        )
        return 1

    account_key = f"{args.user}@jmap"
    db_conn = _init_index_db()

    if not args.full:
        saved_state = _load_saved_sync_state(db_conn, account_key, mailbox_id)
        if saved_state:
            try:
                synced, removed, new_state = _delta_sync(
                    api_url, args.user, account_id, account_key,
                    mailbox_id, saved_state, db_conn,
                )
                db_conn.close()
                result = {
                    "mailbox": mailbox_name,
                    "mailbox_id": mailbox_id,
                    "synced": synced,
                    "removed": removed,
                    "mode": "delta",
                    "state": new_state,
                }
                print(json.dumps(result, indent=2))
                return 0
            except Exception:  # pylint: disable=broad-exception-caught
                # Delta sync failed (e.g., cannotCalculateChanges)
                # Fall through to full sync
                pass

    synced, query_state = _full_sync(
        api_url, args.user, account_id, account_key, mailbox_id, db_conn
    )
    db_conn.close()

    result = {
        "mailbox": mailbox_name,
        "mailbox_id": mailbox_id,
        "synced": synced,
        "mode": "full",
    }
    if query_state:
        result["state"] = query_state
    print(json.dumps(result, indent=2))
    return 0


# ---------------------------------------------------------------------------
# push helpers
# ---------------------------------------------------------------------------

def _build_event_source_url(event_source_url, types):
    """Expand the EventSource URL template with requested types."""
    type_list = types.split(",")
    url = event_source_url
    if "{types}" in url:
        url = url.replace("{types}", ",".join(type_list))
    else:
        separator = "&" if "?" in url else "?"
        url = url + separator + "types=" + ",".join(type_list)
    if "ping=" not in url:
        separator = "&" if "?" in url else "?"
        url = url + separator + "ping=30"
    return url, type_list


def _process_sse_stream(resp, timeout, start_time):
    """Read SSE lines from resp and emit JSON events until timeout."""
    event_type = ""
    event_data = ""

    for raw_line in resp:
        if time.time() - start_time > timeout:
            print(json.dumps({
                "status": "timeout",
                "elapsed_seconds": int(time.time() - start_time),
            }), flush=True)
            break

        line = raw_line.decode("utf-8", errors="replace").rstrip("\r\n")

        if line.startswith("event:"):
            event_type = line[6:].strip()
        elif line.startswith("data:"):
            event_data = line[5:].strip()
        elif line == "" and event_data:
            try:
                data_obj = json.loads(event_data)
            except json.JSONDecodeError:
                data_obj = {"raw": event_data}

            event = {
                "event_type": event_type or "state",
                "data": data_obj,
                "timestamp": datetime.now(timezone.utc).strftime(
                    "%Y-%m-%dT%H:%M:%SZ"
                ),
            }
            print(json.dumps(event), flush=True)
            event_type = ""
            event_data = ""
        # SSE comment / keepalive ping — ignore lines starting with ":"


def cmd_push(args):
    """Subscribe to JMAP push notifications via EventSource (SSE).

    Uses the eventSourceUrl from the JMAP session to receive real-time
    notifications about mailbox changes. This is a long-running operation
    that prints events as JSON lines to stdout.
    """
    session, account_id, _ = _session_context(args)
    event_source_url = session.get("eventSourceUrl", "")

    if not event_source_url:
        print(
            "ERROR: Server does not provide eventSourceUrl "
            "(push not supported)",
            file=sys.stderr,
        )
        return 1

    url, type_list = _build_event_source_url(
        event_source_url, args.types or "mail"
    )
    timeout = args.timeout or 300

    auth_type, credential = _get_auth()
    auth_header = _make_auth_header(args.user, auth_type, credential)

    print(json.dumps({
        "status": "listening",
        "url": url,
        "types": type_list,
        "timeout_seconds": timeout,
        "account_id": account_id,
    }), flush=True)

    req = urllib.request.Request(
        url,
        headers={
            "Authorization": auth_header,
            "Accept": "text/event-stream",
            "Cache-Control": "no-cache",
        },
    )

    start_time = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            _process_sse_stream(resp, timeout, start_time)
    except urllib.error.URLError as exc:
        print(
            f"ERROR: EventSource connection failed: {exc.reason}",
            file=sys.stderr,
        )
        return 1
    except Exception as exc:  # pylint: disable=broad-exception-caught
        # Timeout or connection closed — normal for SSE
        elapsed = int(time.time() - start_time)
        print(json.dumps({
            "status": "disconnected",
            "reason": str(exc),
            "elapsed_seconds": elapsed,
        }), flush=True)

    return 0


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _find_response(method_responses, method_name, call_id):
    """Find a specific method response by name and call ID."""
    for resp in method_responses:
        if len(resp) >= 3 and resp[0] == method_name and resp[2] == call_id:
            return resp[1]
        # Handle error responses
        if len(resp) >= 3 and resp[0] == "error" and resp[2] == call_id:
            err = resp[1] if len(resp) > 1 else {}
            print(
                f"ERROR: JMAP method error ({method_name}): "
                f"{err.get('type', 'unknown')} - "
                f"{err.get('description', '')}",
                file=sys.stderr,
            )
            return None
    return None


def _resolve_mailbox_by_role(mailboxes, name_lower):
    """Return mailbox ID matching a role name, or None."""
    role_map = {
        "inbox": "inbox",
        "sent": "sent",
        "drafts": "drafts",
        "trash": "trash",
        "junk": "junk",
        "spam": "junk",
        "archive": "archive",
        "important": "important",
    }
    target_role = role_map.get(name_lower, "")
    if not target_role:
        return None
    for mb in mailboxes:
        if mb.get("role") == target_role:
            return mb["id"]
    return None


def _resolve_mailbox_by_name(mailboxes, mailbox_name, name_lower):
    """Return mailbox ID by exact or case-insensitive name match, or None."""
    for mb in mailboxes:
        if mb.get("name") == mailbox_name:
            return mb["id"]
    for mb in mailboxes:
        if mb.get("name", "").lower() == name_lower:
            return mb["id"]
    return None


def _resolve_mailbox_by_path(mailboxes, id_to_mailbox, mailbox_name, name_lower):
    """Return mailbox ID by full path match (e.g. Archive/Projects/acme), or None."""
    if "/" not in mailbox_name:
        return None
    for mb in mailboxes:
        path = _build_mailbox_path(mb, id_to_mailbox)
        if path == mailbox_name or path.lower() == name_lower:
            return mb["id"]
    return None


def _resolve_mailbox_id(api_url, user, account_id, mailbox_name):
    """Resolve a mailbox name or path to its JMAP ID.

    Supports:
        - Role names: "inbox", "sent", "drafts", "trash", "junk", "archive"
        - Exact names: "INBOX", "Sent", "My Folder"
        - Paths: "Archive/Projects/acme"
    """
    method_calls = [
        [
            "Mailbox/get",
            {
                "accountId": account_id,
                "properties": ["id", "name", "parentId", "role"],
            },
            "m0",
        ],
    ]

    response = _jmap_request(api_url, user, method_calls)
    get_result = _find_response(
        response.get("methodResponses", []), "Mailbox/get", "m0"
    )

    if not get_result:
        return None

    mailboxes = get_result.get("list", [])
    id_to_mailbox = {mb["id"]: mb for mb in mailboxes}
    name_lower = mailbox_name.lower()

    return (
        _resolve_mailbox_by_role(mailboxes, name_lower)
        or _resolve_mailbox_by_name(mailboxes, mailbox_name, name_lower)
        or _resolve_mailbox_by_path(mailboxes, id_to_mailbox, mailbox_name, name_lower)
    )


def _build_mailbox_path(mailbox, id_to_mailbox):
    """Build the full path for a mailbox by traversing parent chain."""
    parts = [mailbox.get("name", "")]
    current = mailbox
    seen = set()
    while current.get("parentId"):
        parent_id = current["parentId"]
        if parent_id in seen:
            break  # Prevent infinite loops
        seen.add(parent_id)
        parent = id_to_mailbox.get(parent_id)
        if not parent:
            break
        parts.insert(0, parent.get("name", ""))
        current = parent
    return "/".join(parts)


def _format_email_header(em):
    """Format a JMAP email object into a header summary dict."""
    from_addrs = em.get("from") or []
    to_addrs = em.get("to") or []
    keywords = em.get("keywords") or {}

    return {
        "email_id": em.get("id", ""),
        "thread_id": em.get("threadId", ""),
        "message_id": _first_or_empty(em.get("messageId")),
        "date": em.get("receivedAt", ""),
        "from": _format_addresses(from_addrs),
        "to": _format_addresses(to_addrs),
        "subject": em.get("subject", ""),
        "keywords": list(keywords.keys()),
        "size": em.get("size", 0),
        "preview": em.get("preview", ""),
        "mailbox_ids": list((em.get("mailboxIds") or {}).keys()),
    }


def _format_addresses(addr_list):
    """Format a JMAP address list into a display string."""
    if not addr_list:
        return ""
    parts = []
    for addr in addr_list:
        name = addr.get("name", "")
        email_addr = addr.get("email", "")
        if name:
            parts.append(f"{name} <{email_addr}>")
        else:
            parts.append(email_addr)
    return ", ".join(parts)


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------

def build_parser():
    """Build the argument parser with all subcommands."""
    parser = argparse.ArgumentParser(
        description="JMAP adapter for email mailbox operations (RFC 8620/8621)"
    )

    # Common connection arguments
    parser.add_argument(
        "--session-url",
        help="JMAP session URL (e.g., https://api.fastmail.com/jmap/session)",
    )
    parser.add_argument("--user", help="Username (email address)")

    subparsers = parser.add_subparsers(dest="command", help="Command to execute")

    # connect
    subparsers.add_parser("connect", help="Test JMAP connectivity")

    # fetch_headers
    fh = subparsers.add_parser("fetch_headers", help="Fetch email headers")
    fh.add_argument(
        "--mailbox", default="INBOX", help="Mailbox name or role"
    )
    fh.add_argument(
        "--limit", type=int, default=50, help="Max emails to fetch"
    )
    fh.add_argument(
        "--position", type=int, default=0, help="Offset from start"
    )

    # fetch_body
    fb = subparsers.add_parser("fetch_body", help="Fetch an email body by ID")
    fb.add_argument("--email-id", required=True, help="JMAP email ID")

    # search
    sr = subparsers.add_parser("search", help="Search emails")
    sr.add_argument(
        "--filter",
        required=True,
        help='JMAP filter as JSON string or plain text for full-text search',
    )
    sr.add_argument("--mailbox", help="Restrict search to this mailbox")
    sr.add_argument("--limit", type=int, default=50, help="Max results")

    # list_mailboxes
    subparsers.add_parser("list_mailboxes", help="List all JMAP mailboxes")

    # create_mailbox
    cm = subparsers.add_parser("create_mailbox", help="Create a mailbox")
    cm.add_argument(
        "--name", required=True, help="Mailbox name or path (e.g., Archive/Projects)"
    )

    # move_email
    mv = subparsers.add_parser(
        "move_email", help="Move an email to another mailbox"
    )
    mv.add_argument("--email-id", required=True, help="JMAP email ID")
    mv.add_argument(
        "--dest-mailbox", required=True, help="Destination mailbox name"
    )

    # set_keyword
    sk = subparsers.add_parser("set_keyword", help="Set a keyword on an email")
    sk.add_argument("--email-id", required=True, help="JMAP email ID")
    sk.add_argument(
        "--keyword",
        required=True,
        help="Keyword (taxonomy name or JMAP keyword)",
    )

    # clear_keyword
    ck = subparsers.add_parser(
        "clear_keyword", help="Clear a keyword from an email"
    )
    ck.add_argument("--email-id", required=True, help="JMAP email ID")
    ck.add_argument("--keyword", required=True, help="Keyword to clear")

    # index_sync
    ix = subparsers.add_parser(
        "index_sync", help="Sync mailbox to local index"
    )
    ix.add_argument(
        "--mailbox", default="INBOX", help="Mailbox to sync"
    )
    ix.add_argument(
        "--full", action="store_true", help="Full sync (not incremental)"
    )

    # push
    ps = subparsers.add_parser(
        "push", help="Listen for push notifications via EventSource"
    )
    ps.add_argument(
        "--types",
        default="mail",
        help="Comma-separated event types (default: mail)",
    )
    ps.add_argument(
        "--timeout",
        type=int,
        default=300,
        help="Timeout in seconds (default: 300)",
    )

    return parser


def main():
    """Entry point."""
    parser = build_parser()
    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return 1

    # Validate required connection args
    if args.command != "help":
        if not args.session_url or not args.user:
            print(
                "ERROR: --session-url and --user are required",
                file=sys.stderr,
            )
            return 1

    commands = {
        "connect": cmd_connect,
        "fetch_headers": cmd_fetch_headers,
        "fetch_body": cmd_fetch_body,
        "search": cmd_search,
        "list_mailboxes": cmd_list_mailboxes,
        "create_mailbox": cmd_create_mailbox,
        "move_email": cmd_move_email,
        "set_keyword": cmd_set_keyword,
        "clear_keyword": cmd_clear_keyword,
        "index_sync": cmd_index_sync,
        "push": cmd_push,
    }

    handler = commands.get(args.command)
    if handler:
        return handler(args)

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main() or 0)
