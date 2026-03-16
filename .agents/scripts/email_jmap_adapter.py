#!/usr/bin/env python3
"""
email_jmap_adapter.py - JMAP adapter for mailbox operations.

Provides JMAP (RFC 8620/8621) session discovery, mailbox operations,
message search/fetch, keyword updates, and push-style change watching.

Credentials: read from JMAP_ACCESS_TOKEN environment variable.
Output: JSON to stdout. Errors to stderr.
"""

import argparse
import json
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


CAP_CORE = "urn:ietf:params:jmap:core"
CAP_MAIL = "urn:ietf:params:jmap:mail"

INDEX_DIR = Path.home() / ".aidevops" / ".agent-workspace" / "email-mailbox"
INDEX_DB = INDEX_DIR / "index-jmap.db"

FLAG_TAXONOMY = {
    "Reminders": "$Reminder",
    "Tasks": "$Task",
    "Review": "$Review",
    "Filing": "$Filing",
    "Ideas": "$Idea",
    "Add-to-Contacts": "$AddContact",
}


def _utc_now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _fatal(message):
    print(f"ERROR: {message}", file=sys.stderr)
    return 1


def _get_token():
    token = os.environ.get("JMAP_ACCESS_TOKEN", "")
    if not token:
        raise RuntimeError("JMAP_ACCESS_TOKEN environment variable not set")
    return token


def _http_json(method, url, token, payload=None, timeout=30):
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
    }
    data = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(payload).encode("utf-8")

    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            if not raw:
                return {}
            return json.loads(raw.decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code} {exc.reason}: {body}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Network error: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Invalid JSON response: {exc}") from exc


def _init_index_db(db_path=None):
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
            uid         TEXT NOT NULL,
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
    conn.commit()
    try:
        os.chmod(str(db_path), 0o600)
    except OSError:
        pass
    return conn


def _upsert_message(conn, account, folder, msg):
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
        account,
        folder,
        msg.get("uid", ""),
        msg.get("message_id", ""),
        msg.get("date", ""),
        msg.get("from", ""),
        msg.get("to", ""),
        msg.get("subject", ""),
        msg.get("flags", ""),
        int(msg.get("size", 0) or 0),
    ))


def _format_addresses(addresses):
    if not addresses:
        return ""
    parts = []
    for item in addresses:
        email_addr = item.get("email", "")
        name = item.get("name", "")
        if name and email_addr:
            parts.append(f"{name} <{email_addr}>")
        elif email_addr:
            parts.append(email_addr)
    return ", ".join(parts)


def _extract_body(email_obj):
    body_values = email_obj.get("bodyValues", {})

    def _collect(part_refs):
        chunks = []
        for ref in part_refs or []:
            part_id = ref.get("partId", "")
            val = body_values.get(part_id, {})
            if val.get("isTruncated"):
                chunks.append(val.get("value", ""))
            else:
                chunks.append(val.get("value", ""))
        return "\n".join([c for c in chunks if c])

    text_body = _collect(email_obj.get("textBody", []))
    html_body = _collect(email_obj.get("htmlBody", []))
    return text_body, html_body


def _mailbox_name_map(mailboxes):
    by_name = {}
    by_role = {}
    for mb in mailboxes:
        name = (mb.get("name") or "").strip()
        role = (mb.get("role") or "").strip()
        if name:
            by_name[name.lower()] = mb
        if role:
            by_role[role.lower()] = mb
    return by_name, by_role


def _resolve_mailbox_id(mailboxes, folder):
    if not folder:
        return ""
    by_name, by_role = _mailbox_name_map(mailboxes)

    target = folder.strip().lower()
    if target == "inbox" and "inbox" in by_role:
        return by_role["inbox"].get("id", "")
    if target in by_role:
        return by_role[target].get("id", "")
    if target in by_name:
        return by_name[target].get("id", "")
    return ""


def _jmap_to_header(email_obj):
    message_id_list = email_obj.get("messageId", [])
    if isinstance(message_id_list, list) and message_id_list:
        message_id = message_id_list[0]
    else:
        message_id = ""

    keywords = email_obj.get("keywords", {})
    flags = " ".join(sorted([k for k, v in keywords.items() if v]))

    return {
        "uid": email_obj.get("id", ""),
        "message_id": message_id,
        "date": email_obj.get("receivedAt", ""),
        "from": _format_addresses(email_obj.get("from", [])),
        "to": _format_addresses(email_obj.get("to", [])),
        "subject": email_obj.get("subject", ""),
        "flags": flags,
        "size": int(email_obj.get("size", 0) or 0),
    }


def _build_filter_from_query(query, mailbox_id=""):
    query = (query or "").strip()
    if not query:
        filt = {}
    elif query.startswith("{"):
        try:
            filt = json.loads(query)
        except json.JSONDecodeError:
            filt = {"text": query}
    else:
        upper = query.upper()
        filt = {}
        if upper.startswith("FROM "):
            filt["from"] = query[5:].strip().strip('"')
        elif upper.startswith("SUBJECT "):
            filt["subject"] = query[8:].strip().strip('"')
        elif upper.startswith("TEXT "):
            filt["text"] = query[5:].strip().strip('"')
        elif upper.startswith("KEYWORD "):
            filt["hasKeyword"] = query[8:].strip()
        elif upper == "UNSEEN":
            filt["notKeyword"] = "$seen"
        else:
            filt["text"] = query

    if mailbox_id:
        filt["inMailbox"] = mailbox_id
    return filt


class JMAPClient:
    def __init__(self, session_url, token, account_id="", timeout=30):
        self.session_url = session_url
        self.token = token
        self.account_id_override = account_id
        self.timeout = timeout
        self.session = None

    def discover_session(self):
        self.session = _http_json("GET", self.session_url, self.token, timeout=self.timeout)
        return self.session

    def account_id(self):
        if self.account_id_override:
            return self.account_id_override
        if not self.session:
            self.discover_session()
        session = self.session or {}
        primary = session.get("primaryAccounts", {})
        account_id = primary.get(CAP_MAIL, "")
        if not account_id:
            raise RuntimeError("No primary JMAP mail account found")
        return account_id

    def api_url(self):
        if not self.session:
            self.discover_session()
        session = self.session or {}
        api_url = session.get("apiUrl", "")
        if not api_url:
            raise RuntimeError("JMAP session missing apiUrl")
        return api_url

    def call(self, method_calls):
        payload = {
            "using": [CAP_CORE, CAP_MAIL],
            "methodCalls": method_calls,
        }
        return _http_json("POST", self.api_url(), self.token, payload=payload, timeout=self.timeout)

    def mailboxes(self, account_id):
        resp = self.call([
            ["Mailbox/get", {"accountId": account_id}, "mbox"],
        ])
        for entry in resp.get("methodResponses", []):
            if entry[0] == "Mailbox/get" and entry[2] == "mbox":
                return entry[1].get("list", [])
        return []


def _query_emails(client, account_id, folder, limit=50, offset=0, query=""):
    mailboxes = client.mailboxes(account_id)
    mailbox_id = _resolve_mailbox_id(mailboxes, folder)
    filt = _build_filter_from_query(query, mailbox_id)

    query_args = {
        "accountId": account_id,
        "filter": filt,
        "sort": [{"property": "receivedAt", "isAscending": False}],
        "position": int(offset),
        "limit": int(limit),
        "calculateTotal": True,
    }

    response = client.call([
        ["Email/query", query_args, "q1"],
        [
            "Email/get",
            {
                "accountId": account_id,
                "#ids": {"resultOf": "q1", "name": "Email/query", "path": "/ids"},
                "properties": [
                    "id",
                    "messageId",
                    "receivedAt",
                    "from",
                    "to",
                    "subject",
                    "keywords",
                    "size",
                ],
            },
            "g1",
        ],
    ])

    total = 0
    ids = []
    email_list = []
    for method, payload, tag in response.get("methodResponses", []):
        if method == "Email/query" and tag == "q1":
            total = int(payload.get("total", 0) or 0)
            ids = payload.get("ids", [])
        if method == "Email/get" and tag == "g1":
            email_list = payload.get("list", [])

    messages = [_jmap_to_header(obj) for obj in email_list]
    return messages, total, len(ids)


def cmd_connect(args):
    try:
        client = JMAPClient(args.session_url, _get_token(), args.account_id)
        session = client.discover_session()
        account_id = client.account_id()
        result = {
            "status": "connected",
            "session_url": args.session_url,
            "api_url": session.get("apiUrl", ""),
            "event_source_url": session.get("eventSourceUrl", ""),
            "account_id": account_id,
            "capabilities": sorted(list(session.get("capabilities", {}).keys())),
        }
        print(json.dumps(result, indent=2))
        return 0
    except Exception as exc:  # noqa: BLE001
        return _fatal(str(exc))


def cmd_fetch_headers(args):
    try:
        client = JMAPClient(args.session_url, _get_token(), args.account_id)
        account_id = client.account_id()
        folder = args.folder or "INBOX"
        messages, total, matched = _query_emails(
            client,
            account_id,
            folder,
            limit=args.limit,
            offset=args.offset,
            query="",
        )

        db = _init_index_db()
        account_key = f"{account_id}@jmap"
        for msg in messages:
            _upsert_message(db, account_key, folder, msg)
        db.commit()
        db.close()

        result = {
            "folder": folder,
            "total": total,
            "offset": int(args.offset),
            "limit": int(args.limit),
            "returned": len(messages),
            "matched": matched,
            "messages": messages,
        }
        print(json.dumps(result, indent=2))
        return 0
    except Exception as exc:  # noqa: BLE001
        return _fatal(str(exc))


def cmd_fetch_body(args):
    try:
        client = JMAPClient(args.session_url, _get_token(), args.account_id)
        account_id = client.account_id()
        response = client.call([
            [
                "Email/get",
                {
                    "accountId": account_id,
                    "ids": [str(args.uid)],
                    "properties": [
                        "id",
                        "threadId",
                        "messageId",
                        "receivedAt",
                        "from",
                        "to",
                        "cc",
                        "subject",
                        "inReplyTo",
                        "references",
                        "textBody",
                        "htmlBody",
                        "bodyValues",
                        "attachments",
                    ],
                    "fetchAllBodyValues": True,
                },
                "g1",
            ],
        ])

        email_obj = None
        for method, payload, tag in response.get("methodResponses", []):
            if method == "Email/get" and tag == "g1":
                lst = payload.get("list", [])
                if lst:
                    email_obj = lst[0]

        if not email_obj:
            return _fatal(f"Message UID {args.uid} not found")

        text_body, html_body = _extract_body(email_obj)
        msg_ids = email_obj.get("messageId", [])
        result = {
            "uid": email_obj.get("id", ""),
            "folder": args.folder or "INBOX",
            "message_id": msg_ids[0] if msg_ids else "",
            "date": email_obj.get("receivedAt", ""),
            "from": _format_addresses(email_obj.get("from", [])),
            "to": _format_addresses(email_obj.get("to", [])),
            "cc": _format_addresses(email_obj.get("cc", [])),
            "subject": email_obj.get("subject", ""),
            "in_reply_to": " ".join(email_obj.get("inReplyTo", [])),
            "references": " ".join(email_obj.get("references", [])),
            "text_body": text_body,
            "html_body_length": len(html_body),
            "attachments": email_obj.get("attachments", []),
        }
        print(json.dumps(result, indent=2))
        return 0
    except Exception as exc:  # noqa: BLE001
        return _fatal(str(exc))


def cmd_search(args):
    try:
        client = JMAPClient(args.session_url, _get_token(), args.account_id)
        account_id = client.account_id()
        folder = args.folder or "INBOX"
        messages, total, _ = _query_emails(
            client,
            account_id,
            folder,
            limit=args.limit,
            offset=0,
            query=args.query,
        )
        result = {
            "folder": folder,
            "query": args.query,
            "total_matches": total,
            "returned": len(messages),
            "messages": messages,
        }
        print(json.dumps(result, indent=2))
        return 0
    except Exception as exc:  # noqa: BLE001
        return _fatal(str(exc))


def cmd_list_folders(args):
    try:
        client = JMAPClient(args.session_url, _get_token(), args.account_id)
        account_id = client.account_id()
        folders = client.mailboxes(account_id)
        result_folders = []
        for mb in folders:
            result_folders.append(
                {
                    "id": mb.get("id", ""),
                    "name": mb.get("name", ""),
                    "role": mb.get("role", ""),
                    "parentId": mb.get("parentId", ""),
                    "sortOrder": mb.get("sortOrder", 0),
                    "totalEmails": mb.get("totalEmails", 0),
                    "unreadEmails": mb.get("unreadEmails", 0),
                }
            )
        print(json.dumps({"total": len(result_folders), "folders": result_folders}, indent=2))
        return 0
    except Exception as exc:  # noqa: BLE001
        return _fatal(str(exc))


def cmd_create_folder(args):
    try:
        client = JMAPClient(args.session_url, _get_token(), args.account_id)
        account_id = client.account_id()

        folder = (args.folder or "").strip()
        if not folder:
            return _fatal("--folder is required")

        parent_id = None
        leaf_name = folder
        if "/" in folder:
            parent_name, leaf_name = folder.rsplit("/", 1)
            mailboxes = client.mailboxes(account_id)
            parent_id = _resolve_mailbox_id(mailboxes, parent_name)

        create_obj = {"name": leaf_name}
        if parent_id:
            create_obj["parentId"] = parent_id

        response = client.call([
            [
                "Mailbox/set",
                {
                    "accountId": account_id,
                    "create": {"c1": create_obj},
                },
                "s1",
            ],
        ])

        created_id = ""
        not_created = None
        for method, payload, tag in response.get("methodResponses", []):
            if method == "Mailbox/set" and tag == "s1":
                created = payload.get("created", {}).get("c1", {})
                created_id = created.get("id", "")
                not_created = payload.get("notCreated", {}).get("c1")

        if not_created:
            return _fatal(f"Mailbox create failed: {json.dumps(not_created)}")

        print(json.dumps({"status": "created", "folder": folder, "id": created_id}, indent=2))
        return 0
    except Exception as exc:  # noqa: BLE001
        return _fatal(str(exc))


def cmd_move_message(args):
    try:
        client = JMAPClient(args.session_url, _get_token(), args.account_id)
        account_id = client.account_id()
        uid = str(args.uid)
        dest_name = args.dest
        if not dest_name:
            return _fatal("--dest is required")

        mailboxes = client.mailboxes(account_id)
        dest_id = _resolve_mailbox_id(mailboxes, dest_name)
        if not dest_id:
            return _fatal(f"Destination folder not found: {dest_name}")

        response = client.call([
            [
                "Email/set",
                {
                    "accountId": account_id,
                    "update": {
                        uid: {
                            "mailboxIds": {dest_id: True},
                        }
                    },
                },
                "s1",
            ],
        ])

        not_updated = None
        for method, payload, tag in response.get("methodResponses", []):
            if method == "Email/set" and tag == "s1":
                not_updated = payload.get("notUpdated", {}).get(uid)

        if not_updated:
            return _fatal(f"Move failed: {json.dumps(not_updated)}")

        result = {
            "status": "moved",
            "uid": uid,
            "from_folder": args.folder or "INBOX",
            "to_folder": dest_name,
        }
        print(json.dumps(result, indent=2))
        return 0
    except Exception as exc:  # noqa: BLE001
        return _fatal(str(exc))


def _set_keyword(args, enabled):
    try:
        client = JMAPClient(args.session_url, _get_token(), args.account_id)
        account_id = client.account_id()
        uid = str(args.uid)
        keyword = FLAG_TAXONOMY.get(args.flag, args.flag)
        patch_key = f"keywords/{keyword}"

        response = client.call([
            [
                "Email/set",
                {
                    "accountId": account_id,
                    "update": {uid: {patch_key: bool(enabled)}},
                },
                "s1",
            ],
        ])

        not_updated = None
        for method, payload, tag in response.get("methodResponses", []):
            if method == "Email/set" and tag == "s1":
                not_updated = payload.get("notUpdated", {}).get(uid)

        if not_updated:
            return _fatal(f"Flag update failed: {json.dumps(not_updated)}")

        status = "flag_set" if enabled else "flag_cleared"
        result = {
            "status": status,
            "uid": uid,
            "folder": args.folder or "INBOX",
            "flag": keyword,
        }
        print(json.dumps(result, indent=2))
        return 0
    except Exception as exc:  # noqa: BLE001
        return _fatal(str(exc))


def cmd_set_flag(args):
    return _set_keyword(args, True)


def cmd_clear_flag(args):
    return _set_keyword(args, False)


def cmd_index_sync(args):
    try:
        client = JMAPClient(args.session_url, _get_token(), args.account_id)
        account_id = client.account_id()
        folder = args.folder or "INBOX"

        limit = 500 if args.full else 200
        messages, total, _ = _query_emails(
            client,
            account_id,
            folder,
            limit=limit,
            offset=0,
            query="",
        )

        db = _init_index_db()
        account_key = f"{account_id}@jmap"
        for msg in messages:
            _upsert_message(db, account_key, folder, msg)
        db.commit()
        db.close()

        result = {
            "folder": folder,
            "total": total,
            "synced": len(messages),
            "mode": "full" if args.full else "incremental",
        }
        print(json.dumps(result, indent=2))
        return 0
    except Exception as exc:  # noqa: BLE001
        return _fatal(str(exc))


def _render_change_event(changed, source):
    item = {
        "event": "mailbox_changed",
        "source": source,
        "changed": changed,
        "timestamp": _utc_now_iso(),
    }
    print(json.dumps(item))


def _watch_event_source(client, account_id, timeout, heartbeat):
    session = client.session or client.discover_session()
    event_url = session.get("eventSourceUrl", "")
    if not event_url:
        return False

    url = event_url
    url = url.replace("{types}", urllib.parse.quote("Email"))
    url = url.replace("{closeafter}", str(timeout))
    url = url.replace("{ping}", str(heartbeat))
    url = url.replace("{sinceState}", "")

    headers = {
        "Authorization": f"Bearer {client.token}",
        "Accept": "text/event-stream",
    }
    req = urllib.request.Request(url, method="GET", headers=headers)
    started = time.time()

    try:
        with urllib.request.urlopen(req, timeout=max(heartbeat + 5, 10)) as resp:
            while time.time() - started < timeout:
                line = resp.readline()
                if not line:
                    break
                text = line.decode("utf-8", errors="replace").strip()
                if not text.startswith("data:"):
                    continue
                payload_str = text[5:].strip()
                if not payload_str:
                    continue
                try:
                    payload = json.loads(payload_str)
                except json.JSONDecodeError:
                    continue

                changed = payload.get("changed")
                if changed:
                    changed_for_account = changed.get(account_id, changed)
                    _render_change_event(changed_for_account, "event_source")
        return True
    except Exception:  # noqa: BLE001
        return False


def _watch_polling(client, account_id, folder, timeout, heartbeat):
    mailboxes = client.mailboxes(account_id)
    mailbox_id = _resolve_mailbox_id(mailboxes, folder)
    filt = {}
    if mailbox_id:
        filt["inMailbox"] = mailbox_id

    initial = client.call([
        [
            "Email/query",
            {
                "accountId": account_id,
                "filter": filt,
                "sort": [{"property": "receivedAt", "isAscending": False}],
                "limit": 1,
            },
            "q1",
        ]
    ])
    state = ""
    for method, payload, tag in initial.get("methodResponses", []):
        if method == "Email/query" and tag == "q1":
            state = payload.get("queryState", "")

    started = time.time()
    while time.time() - started < timeout:
        time.sleep(max(1, int(heartbeat)))
        if not state:
            break
        resp = client.call([
            [
                "Email/queryChanges",
                {
                    "accountId": account_id,
                    "filter": filt,
                    "sort": [{"property": "receivedAt", "isAscending": False}],
                    "sinceQueryState": state,
                    "maxChanges": 100,
                },
                "qc1",
            ]
        ])

        next_state = state
        for method, payload, tag in resp.get("methodResponses", []):
            if method == "Email/queryChanges" and tag == "qc1":
                next_state = payload.get("newQueryState", state)
                added = payload.get("added", [])
                if added:
                    ids = [item.get("id", "") for item in added if item.get("id")]
                    _render_change_event({"added": ids}, "query_changes")
        state = next_state


def cmd_watch_changes(args):
    try:
        client = JMAPClient(args.session_url, _get_token(), args.account_id)
        account_id = client.account_id()
        timeout = int(args.timeout or 300)
        heartbeat = int(args.heartbeat or 20)
        folder = args.folder or "INBOX"

        used_event_source = _watch_event_source(client, account_id, timeout, heartbeat)
        if not used_event_source:
            _watch_polling(client, account_id, folder, timeout, heartbeat)

        print(
            json.dumps(
                {
                    "status": "watch_complete",
                    "folder": folder,
                    "timeout": timeout,
                    "heartbeat": heartbeat,
                    "mode": "event_source" if used_event_source else "query_changes",
                },
                indent=2,
            )
        )
        return 0
    except Exception as exc:  # noqa: BLE001
        return _fatal(str(exc))


def build_parser():
    parser = argparse.ArgumentParser(description="JMAP adapter for email mailbox operations")
    parser.add_argument("--session-url", required=True, help="JMAP session URL")
    parser.add_argument("--account-id", default="", help="Optional JMAP account ID override")

    subparsers = parser.add_subparsers(dest="command", help="Command to execute")

    subparsers.add_parser("connect", help="Test JMAP session connectivity")

    fh = subparsers.add_parser("fetch_headers", help="Fetch message headers")
    fh.add_argument("--folder", default="INBOX", help="Folder/mailbox to fetch from")
    fh.add_argument("--limit", type=int, default=50, help="Max messages to fetch")
    fh.add_argument("--offset", type=int, default=0, help="Offset from most recent")

    fb = subparsers.add_parser("fetch_body", help="Fetch a message by JMAP email id")
    fb.add_argument("--uid", required=True, help="JMAP email id")
    fb.add_argument("--folder", default="INBOX", help="Folder containing the message")

    sr = subparsers.add_parser("search", help="Search messages")
    sr.add_argument("--query", required=True, help="Search query (JSON filter or text)")
    sr.add_argument("--folder", default="INBOX", help="Folder to search")
    sr.add_argument("--limit", type=int, default=50, help="Max results")

    subparsers.add_parser("list_folders", help="List mailboxes")

    cf = subparsers.add_parser("create_folder", help="Create a mailbox")
    cf.add_argument("--folder", required=True, help="Folder path to create")

    mv = subparsers.add_parser("move_message", help="Move message to destination folder")
    mv.add_argument("--uid", required=True, help="JMAP email id")
    mv.add_argument("--dest", required=True, help="Destination folder")
    mv.add_argument("--folder", default="INBOX", help="Source folder label for output")

    sf = subparsers.add_parser("set_flag", help="Set a keyword flag")
    sf.add_argument("--uid", required=True, help="JMAP email id")
    sf.add_argument("--flag", required=True, help="Flag name")
    sf.add_argument("--folder", default="INBOX", help="Folder label for output")

    clf = subparsers.add_parser("clear_flag", help="Clear a keyword flag")
    clf.add_argument("--uid", required=True, help="JMAP email id")
    clf.add_argument("--flag", required=True, help="Flag name")
    clf.add_argument("--folder", default="INBOX", help="Folder label for output")

    ix = subparsers.add_parser("index_sync", help="Sync folder metadata to local index")
    ix.add_argument("--folder", default="INBOX", help="Folder to sync")
    ix.add_argument("--full", action="store_true", help="Full sync")

    wt = subparsers.add_parser("watch_changes", help="Watch for new mail (JMAP push/poll)")
    wt.add_argument("--folder", default="INBOX", help="Folder to watch")
    wt.add_argument("--timeout", type=int, default=300, help="Watch timeout in seconds")
    wt.add_argument("--heartbeat", type=int, default=20, help="Polling fallback interval")

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()

    if not args.command:
        parser.print_help()
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
        "watch_changes": cmd_watch_changes,
    }

    handler = commands.get(args.command)
    if not handler:
        parser.print_help()
        return 1
    return handler(args)


if __name__ == "__main__":
    sys.exit(main() or 0)
