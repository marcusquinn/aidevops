#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email_jmap_helpers.py - Shared JMAP response parsing and formatting helpers.

Extracted from email_jmap_adapter.py to reduce file-level complexity.
Provides mailbox resolution, email header formatting, and response parsing.
"""

import sys

from email_jmap_index import _first_or_empty
from email_jmap_transport import _jmap_request


# ---------------------------------------------------------------------------
# Response parsing
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


# ---------------------------------------------------------------------------
# Mailbox resolution
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

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
