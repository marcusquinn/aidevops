#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
oauth-pool-lib/pool_ops_rotate.py — rotate command implementation.

Rotates ``auth.json`` to the next available account in the pool. Extracted
from ``pool_ops.py`` during the t2069 decomposition.

Env: POOL_FILE_PATH, AUTH_FILE_PATH, PROVIDER, UA_HEADER (optional)
"""

from __future__ import annotations

import json
import os
import sys
import time
from datetime import datetime, timezone

from ._common import (
    CLIENT_IDS,
    TOKEN_URLS,
    acquire_lock,
    atomic_write_json,
    build_auth_entry,
    call_token_endpoint,
    release_lock,
)


def _try_refresh_token(account: dict, provider: str, now_ms: int, ua_header: str) -> None:
    """Attempt to refresh ``account``'s access token in place.

    No-ops if the provider has no token endpoint or the account has no
    refresh token. Errors are logged to stderr and swallowed — rotation
    must continue even if the refresh fails.
    """
    refresh_tok = account.get("refresh", "")
    token_url = TOKEN_URLS.get(provider, "")
    client_id = CLIENT_IDS.get(provider, "")
    if not (refresh_tok and token_url and client_id):
        return
    rdata = call_token_endpoint(token_url, client_id, refresh_tok, ua_header)
    if rdata is None:
        print("REFRESH_FAILED", file=sys.stderr)
        return
    new_access = rdata.get("access_token", "")
    if not new_access:
        return
    account["access"] = new_access
    account["refresh"] = rdata.get("refresh_token", refresh_tok)
    account["expires"] = now_ms + int(rdata.get("expires_in", 3600)) * 1000
    account["status"] = "active"
    print("REFRESHED", file=sys.stderr)


def _identify_current_email(accounts: list[dict], current_access: str) -> str:
    """Resolve which account the current ``auth.json`` access token belongs to.

    Falls back to the most recently used account if no access token matches.
    """
    if current_access:
        for a in accounts:
            if a.get("access", "") == current_access:
                return a.get("email", "unknown")
    sorted_by_used = sorted(accounts, key=lambda a: a.get("lastUsed", ""), reverse=True)
    return sorted_by_used[0].get("email", "unknown")


def _is_immediately_available(account: dict, current_email: str, now_ms: int) -> bool:
    """Tier-1 check: the account is non-current, active/idle, and not in cooldown."""
    if account.get("email") == current_email:
        return False
    if account.get("status", "active") not in ("active", "idle"):
        return False
    cd = account.get("cooldownUntil")
    return not cd or cd <= now_ms


def _select_rotation_candidate(
    accounts: list[dict],
    current_email: str,
    now_ms: int,
) -> tuple[dict | None, bool]:
    """Pick the next account to rotate to.

    Returns ``(next_account, all_rate_limited)``. When all accounts are
    rate-limited (Tier 2), ``all_rate_limited`` is True and the candidate
    is the one with the *shortest* cooldown remaining. Otherwise (Tier 1),
    candidates are sorted by ``(-priority, lastUsed)``.
    """
    candidates = [a for a in accounts if _is_immediately_available(a, current_email, now_ms)]
    if candidates:
        candidates.sort(key=lambda a: (-(a.get("priority") or 0), a.get("lastUsed", "")))
        return candidates[0], False

    fallback = sorted(accounts, key=lambda a: a.get("cooldownUntil") or 0)
    if not fallback:
        return None, True
    return fallback[0], True


def _update_last_used(pool: dict, provider: str, email: str) -> None:
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    for a in pool[provider]:
        if a.get("email") == email:
            a["lastUsed"] = now_iso
            return


def _print_rotation_outcome(
    all_rate_limited: bool,
    next_account: dict,
    current_email: str,
    next_email: str,
    now_ms: int,
) -> None:
    if all_rate_limited:
        cd = next_account.get("cooldownUntil") or 0
        wait_mins = max(0, (cd - now_ms + 59999) // 60000) if cd > now_ms else 0
        print(f"OK_COOLDOWN:{wait_mins}")
    else:
        print("OK")
    print(current_email)
    print(next_email)


def cmd_rotate() -> None:
    pool_path = os.environ["POOL_FILE_PATH"]
    auth_path = os.environ["AUTH_FILE_PATH"]
    provider = os.environ["PROVIDER"]
    ua_header = os.environ.get("UA_HEADER", "aidevops/1.0")

    lock_path = pool_path + ".lock"
    lock_fd = open(lock_path, "w")

    # State that crosses the lock boundary so we can print after releasing.
    all_rate_limited = False
    next_account: dict | None = None
    current_email = ""
    next_email = ""
    now_ms = int(time.time() * 1000)

    try:
        acquire_lock(lock_fd)

        with open(pool_path) as f:
            pool = json.load(f)
        accounts = pool.get(provider, [])
        if len(accounts) < 2:
            print("ERROR:need_accounts")
            sys.exit(0)

        with open(auth_path) as f:
            auth = json.load(f)
        current_auth = auth.get(provider, {})
        current_access = current_auth.get("access", "")

        current_email = _identify_current_email(accounts, current_access)

        now_ms = int(time.time() * 1000)
        next_account, all_rate_limited = _select_rotation_candidate(accounts, current_email, now_ms)
        if next_account is None:
            print("ERROR:no_alternate")
            sys.exit(0)

        next_email = next_account.get("email", "unknown")

        # Auto-refresh if expired and refresh token available
        if next_account.get("expires", 0) <= now_ms and next_account.get("refresh"):
            _try_refresh_token(next_account, provider, now_ms, ua_header)

        auth[provider] = build_auth_entry(provider, next_account, current_auth)
        atomic_write_json(auth_path, auth)

        _update_last_used(pool, provider, next_email)
        atomic_write_json(pool_path, pool)
    finally:
        release_lock(lock_fd)
        lock_fd.close()

    _print_rotation_outcome(all_rate_limited, next_account, current_email, next_email, now_ms)
