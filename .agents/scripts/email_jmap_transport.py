#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email_jmap_transport.py - JMAP HTTP transport and session management.

Extracted from email_jmap_adapter.py to reduce file-level complexity.
Handles authentication, HTTP requests, and JMAP session discovery (RFC 8620).
"""

import json
import os
import sys
import urllib.error
import urllib.request


# ---------------------------------------------------------------------------
# Authentication
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


# ---------------------------------------------------------------------------
# JMAP HTTP requests
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Session management (RFC 8620 Section 2)
# ---------------------------------------------------------------------------

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
