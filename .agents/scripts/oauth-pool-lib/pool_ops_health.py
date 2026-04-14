#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
oauth-pool-lib/pool_ops_health.py — health-check command implementations.

Read-only diagnostic commands used by ``oauth-pool-helper.sh check``.
Extracted from ``pool_ops.py`` during the t2069 decomposition.
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def cmd_check_accounts() -> None:
    """check-accounts: Print account details for health check.

    Env: PROV, NOW_MS
    """
    pool = json.load(sys.stdin)
    prov = os.environ["PROV"]
    now = int(os.environ["NOW_MS"])
    for a in pool.get(prov, []):
        expires_in = a.get("expires", 0) - now
        print(json.dumps({"email": a["email"], "expires_in": expires_in, "account": a}))


def _build_anthropic_validate_request(token: str, ua: str) -> Request:
    req = Request("https://api.anthropic.com/v1/models", method="GET")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("User-Agent", ua)
    req.add_header("anthropic-version", "2023-06-01")
    req.add_header("anthropic-beta", "oauth-2025-04-20")
    return req


def _build_google_validate_request(token: str) -> Request:
    req = Request(
        "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1",
        method="GET",
    )
    req.add_header("Authorization", f"Bearer {token}")
    return req


def _format_validate_http_error(err: HTTPError, prov: str) -> str:
    if err.code == 401:
        return "    Validity: INVALID (401 - needs refresh)"
    if prov == "google" and err.code == 403:
        return "    Validity: OK (403 - token valid, check AI Pro/Ultra subscription)"
    return f"    Validity: HTTP {err.code}"


def cmd_check_validate() -> None:
    """check-validate: Validate a token against provider API.

    Env: PROV, EXPIRES_IN, TOKEN, UA
    """
    prov = os.environ["PROV"]
    expires_in = int(os.environ["EXPIRES_IN"])
    token = os.environ["TOKEN"]
    ua = os.environ["UA"]

    if prov not in ("anthropic", "google"):
        raise SystemExit(0)
    if not token:
        print("    Validity: no access token")
        raise SystemExit(0)
    if expires_in <= 0:
        print("    Validity: EXPIRED - will auto-refresh on next use")
        raise SystemExit(0)

    if prov == "anthropic":
        req = _build_anthropic_validate_request(token, ua)
    else:
        req = _build_google_validate_request(token)
    try:
        urlopen(req, timeout=10)
        print("    Validity: OK")
    except HTTPError as e:
        print(_format_validate_http_error(e, prov))
    except (URLError, OSError):
        print("    Validity: ERROR (network)")
    except Exception:
        print("    Validity: ERROR")


def _format_last_used(lu: str, now_ms: int) -> str:
    """Render the ``Last used:`` line for ``check-meta``.

    Falls back to printing the raw timestamp on parse failure.
    """
    try:
        lu_ts = datetime.fromisoformat(lu.replace("Z", "+00:00")).timestamp() * 1000
    except Exception:
        return f"    Last used: {lu}"
    ago = now_ms - lu_ts
    ago_mins = int(ago // 60000)
    ago_hours = ago_mins // 60
    if ago_hours > 0:
        return f"    Last used: {ago_hours}h {ago_mins % 60}m ago"
    return f"    Last used: {ago_mins}m ago"


def cmd_check_meta() -> None:
    """check-meta: Print account metadata.

    Env: NOW_MS
    """
    a = json.load(sys.stdin)
    now = int(os.environ["NOW_MS"])
    print(f"    Status: {a.get('status', 'unknown')}")
    cd = a.get("cooldownUntil")
    if cd and cd > now:
        cd_mins = (cd - now + 59999) // 60000
        print(f"    Cooldown: {cd_mins}m remaining")
    lu = a.get("lastUsed")
    if lu:
        print(_format_last_used(lu, now))
    print(f"    Refresh token: {'present' if a.get('refresh') else 'MISSING'}")


def cmd_check_expiry() -> None:
    """check-expiry: Print token expiry info.

    Env: EXPIRES_IN (milliseconds remaining)
    """
    expires_in = int(os.environ["EXPIRES_IN"])
    if expires_in <= 0:
        print("    Token: EXPIRED")
        return
    mins = expires_in // 60000
    hours = mins // 60
    if hours > 0:
        print(f"    Token: expires in {hours}h {mins % 60}m")
    else:
        print(f"    Token: expires in {mins}m")
