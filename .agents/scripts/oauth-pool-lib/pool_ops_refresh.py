#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
oauth-pool-lib/pool_ops_refresh.py — refresh command implementation.

Refreshes expired tokens for one or all accounts in a provider's pool, and
back-fills ``auth.json`` when the active credential is empty/missing/expired
(self-heal). Extracted from the monolithic ``pool_ops.py`` during the t2069
decomposition; ``cmd_refresh`` was the single highest-complexity function in
the repo (cyclomatic 72) before this split.

Env: POOL_FILE_PATH, AUTH_FILE_PATH, PROVIDER, TARGET_EMAIL, UA_HEADER (optional)
"""

from __future__ import annotations

import json
import os
import sys
import time
from typing import NamedTuple

from ._common import (
    CLIENT_IDS,
    TOKEN_URLS,
    acquire_lock,
    atomic_write_json,
    build_auth_entry,
    call_token_endpoint,
    release_lock,
)


# Window before expiry that still triggers a refresh (1 hour).
_EXPIRY_REFRESH_WINDOW_MS = 3_600_000


class _RefreshContext(NamedTuple):
    """Per-run configuration for a refresh sweep.

    Bundles the inputs that don't change between accounts so that helper
    signatures stay narrow (qlty caps function-parameter count at 5).
    """

    token_url: str
    client_id: str
    ua_header: str
    target_email: str


def _should_refresh_account(account: dict, target_email: str, now_ms: int) -> bool:
    """Decide whether ``account`` is eligible for refresh in this run."""
    email = account.get("email", "unknown")
    if target_email != "all" and email != target_email:
        return False
    if not account.get("refresh", ""):
        return False
    expires = account.get("expires", 0)
    if expires and expires > now_ms + _EXPIRY_REFRESH_WINDOW_MS:
        return False
    return True


def _apply_refresh_response(account: dict, rdata: dict, now_ms: int) -> bool:
    """Apply a successful token response to ``account`` in place.

    Returns True iff the response carried a non-empty ``access_token``.
    """
    new_access = rdata.get("access_token", "")
    if not new_access:
        return False
    account["access"] = new_access
    account["refresh"] = rdata.get("refresh_token", account.get("refresh", ""))
    new_expires_in = int(rdata.get("expires_in", 3600))
    account["expires"] = now_ms + new_expires_in * 1000
    account["status"] = "active"
    return True


def _refresh_one_account(
    account: dict,
    ctx: _RefreshContext,
    now_ms: int,
) -> tuple[bool, str]:
    """Refresh a single account.

    Returns ``(success, error_label)``. ``error_label`` is empty on success,
    or ``"<email>"`` / ``"<email>(network)"`` on failure for the caller to
    forward into the failed-list.
    """
    email = account.get("email", "unknown")
    refresh_tok = account.get("refresh", "")
    rdata = call_token_endpoint(ctx.token_url, ctx.client_id, refresh_tok, ctx.ua_header)
    if rdata is None:
        return False, f"{email}(network)"
    if _apply_refresh_response(account, rdata, now_ms):
        return True, ""
    return False, email


def _refresh_all_eligible(
    accounts: list[dict],
    ctx: _RefreshContext,
    now_ms: int,
) -> tuple[list[str], list[str]]:
    """Walk the account list, refresh eligible ones, return (refreshed, failed)."""
    refreshed: list[str] = []
    failed: list[str] = []
    for acct in accounts:
        if not _should_refresh_account(acct, ctx.target_email, now_ms):
            continue
        ok, err_label = _refresh_one_account(acct, ctx, now_ms)
        if ok:
            refreshed.append(acct.get("email", "unknown"))
        else:
            failed.append(err_label)
    return refreshed, failed


def _auth_needs_heal(provider_auth: dict, now_ms: int) -> bool:
    """Self-heal trigger (GH#17487): active credential empty / missing / expired."""
    current_access = provider_auth.get("access", "")
    if not current_access:
        return True
    auth_expires = provider_auth.get("expires", 0)
    if not auth_expires:
        return True
    return auth_expires <= now_ms


def _pick_heal_account(accounts: list[dict], refreshed_emails: list[str], now_ms: int) -> dict | None:
    """Choose which pool account should populate auth.json after self-heal.

    Prefers a just-refreshed account; falls back to any account with a
    non-empty access token that isn't expired.
    """
    for acct in accounts:
        if acct.get("email") in refreshed_emails:
            return acct
    for acct in accounts:
        if acct.get("access") and acct.get("expires", 0) > now_ms:
            return acct
    return None


def _self_heal_auth_file(
    auth_path: str,
    provider: str,
    accounts: list[dict],
    refreshed_emails: list[str],
    now_ms: int,
) -> None:
    """If auth.json's active credential is missing/expired, back-fill from pool."""
    if not os.path.exists(auth_path):
        return
    with open(auth_path) as f:
        auth = json.load(f)
    provider_auth = auth.get(provider, {}) if isinstance(auth, dict) else {}
    if not _auth_needs_heal(provider_auth, now_ms):
        return
    heal_acct = _pick_heal_account(accounts, refreshed_emails, now_ms)
    if heal_acct is None:
        return
    auth[provider] = build_auth_entry(provider, heal_acct, provider_auth)
    atomic_write_json(auth_path, auth)
    print(f'HEALED_AUTH:{provider}:{heal_acct.get("email", "")}', file=sys.stderr)


def _print_refresh_results(refreshed: list[str], failed: list[str]) -> None:
    for e in refreshed:
        print(f"REFRESHED:{e}")
    for e in failed:
        print(f"FAILED:{e}")
    if not refreshed and not failed:
        print("NONE")


def cmd_refresh() -> None:
    pool_path = os.environ["POOL_FILE_PATH"]
    auth_path = os.environ["AUTH_FILE_PATH"]
    provider = os.environ["PROVIDER"]
    target_email = os.environ["TARGET_EMAIL"]
    ua_header = os.environ.get("UA_HEADER", "aidevops/1.0")

    token_url = TOKEN_URLS.get(provider, "")
    client_id = CLIENT_IDS.get(provider, "")
    if not token_url or not client_id:
        print("ERROR:no_endpoint")
        sys.exit(0)

    ctx = _RefreshContext(
        token_url=token_url,
        client_id=client_id,
        ua_header=ua_header,
        target_email=target_email,
    )

    lock_path = pool_path + ".lock"
    lock_fd = open(lock_path, "w")
    refreshed: list[str] = []
    failed: list[str] = []
    try:
        acquire_lock(lock_fd)

        with open(pool_path) as f:
            pool = json.load(f)
        accounts = pool.get(provider, [])
        now_ms = int(time.time() * 1000)

        refreshed, failed = _refresh_all_eligible(accounts, ctx, now_ms)

        if refreshed:
            atomic_write_json(pool_path, pool)
            _self_heal_auth_file(auth_path, provider, accounts, refreshed, now_ms)
    finally:
        release_lock(lock_fd)
        lock_fd.close()

    _print_refresh_results(refreshed, failed)
