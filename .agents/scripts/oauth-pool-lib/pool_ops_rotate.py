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
    pool_account_key,
    pool_account_label,
    release_lock,
    token_refresh_error_label,
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
    error_label = token_refresh_error_label(rdata)
    if error_label:
        print(f"REFRESH_FAILED:{error_label}", file=sys.stderr)
        return
    new_access = rdata.get("access_token", "")
    if not new_access:
        return
    account["access"] = new_access
    account["refresh"] = rdata.get("refresh_token", refresh_tok)
    account["expires"] = now_ms + int(rdata.get("expires_in", 3600)) * 1000
    account["status"] = "active"
    print("REFRESHED", file=sys.stderr)


def _identify_current_account(accounts: list[dict], current_access: str) -> dict:
    """Resolve which seat the current ``auth.json`` access token belongs to.

    Falls back to the most recently used seat if no access token matches.
    Identity is the seat key (email + optional orgId, GH#38959), so a Team and
    a Personal seat on one email are distinct rotation candidates.
    """
    if current_access:
        for a in accounts:
            if a.get("access", "") == current_access:
                return a
    return sorted(accounts, key=lambda a: a.get("lastUsed", ""), reverse=True)[0]


def _is_immediately_available(account: dict, current_key: str, now_ms: int) -> bool:
    """Tier-1 check: the account is non-current, active/idle, and not in cooldown."""
    if pool_account_key(account) == current_key:
        return False
    if account.get("status", "active") not in ("active", "idle"):
        return False
    cd = account.get("cooldownUntil")
    return not cd or cd <= now_ms


USAGE_REMAINING_FLOOR_PCT = 5
USAGE_MAX_AGE_MS = 8 * 24 * 60 * 60 * 1000


def _to_ms(value: object) -> int:
    try:
        n = float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return 0
    if n != n or n <= 0:
        return 0
    return int(n * 1000) if n < 1e12 else int(n)


def _reset_sort_key(account: dict, now_ms: int) -> tuple[int, int]:
    """Reset-aware ordering key (t19125); mirrors oauth-pool-ordering.mjs.

    ``(0, resetAt)`` for a seat with a future reset, fresh data and quota above
    the floor (earliest deadline first); ``(1, 0)`` otherwise, so seats without
    data keep the caller's LRU tiebreak.
    """
    reset = _to_ms(account.get("usageResetAt"))
    if not reset or reset <= now_ms:
        return (1, 0)
    observed = _to_ms(account.get("usageObservedAt"))
    if observed and now_ms - observed > USAGE_MAX_AGE_MS:
        return (1, 0)
    pct = account.get("usageRemainingPct")
    if isinstance(pct, (int, float)) and not isinstance(pct, bool) and pct <= USAGE_REMAINING_FLOOR_PCT:
        return (1, 0)
    return (0, reset)


def _select_rotation_candidate(
    accounts: list[dict],
    current_key: str,
    now_ms: int,
) -> tuple[dict | None, bool]:
    """Pick the next account to rotate to.

    Returns ``(next_account, all_rate_limited)``. When all accounts are
    rate-limited (Tier 2), ``all_rate_limited`` is True and the candidate
    is the one with the *shortest* cooldown remaining. Otherwise (Tier 1),
    candidates are sorted by ``(-priority, reset group, reset, lastUsed)``;
    seats with no usable reset data fall back to ``(-priority, lastUsed)``.
    """
    candidates = [a for a in accounts if _is_immediately_available(a, current_key, now_ms)]
    if candidates:
        candidates.sort(
            key=lambda a: (-(a.get("priority") or 0), *_reset_sort_key(a, now_ms), a.get("lastUsed", ""))
        )
        return candidates[0], False

    fallback = sorted(accounts, key=lambda a: a.get("cooldownUntil") or 0)
    if not fallback:
        return None, True
    return fallback[0], True


def _update_last_used(pool: dict, provider: str, seat_key: str) -> None:
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    for a in pool[provider]:
        if pool_account_key(a) == seat_key:
            a["lastUsed"] = now_iso
            return


def _print_rotation_outcome(
    all_rate_limited: bool,
    next_account: dict,
    current_label: str,
    next_label: str,
    now_ms: int,
) -> None:
    if all_rate_limited:
        cd = next_account.get("cooldownUntil") or 0
        wait_mins = max(0, (cd - now_ms + 59999) // 60000) if cd > now_ms else 0
        print(f"OK_COOLDOWN:{wait_mins}")
    else:
        print("OK")
    print(current_label)
    print(next_label)


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
    current_label = ""
    next_label = ""
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

        current_account = _identify_current_account(accounts, current_access)
        current_label = pool_account_label(current_account)

        now_ms = int(time.time() * 1000)
        next_account, all_rate_limited = _select_rotation_candidate(
            accounts, pool_account_key(current_account), now_ms)
        if next_account is None:
            print("ERROR:no_alternate")
            sys.exit(0)

        next_label = pool_account_label(next_account)

        # Auto-refresh if expired and refresh token available
        if next_account.get("expires", 0) <= now_ms and next_account.get("refresh"):
            _try_refresh_token(next_account, provider, now_ms, ua_header)

        auth[provider] = build_auth_entry(provider, next_account, current_auth)
        atomic_write_json(auth_path, auth)

        _update_last_used(pool, provider, pool_account_key(next_account))
        atomic_write_json(pool_path, pool)
    finally:
        release_lock(lock_fd)
        lock_fd.close()

    _print_rotation_outcome(all_rate_limited, next_account, current_label, next_label, now_ms)
