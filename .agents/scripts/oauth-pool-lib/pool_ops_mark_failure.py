#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
oauth-pool-lib/pool_ops_mark_failure.py — mark-failure command implementation.

Marks the currently-active account as failed (rate-limited or auth-error)
and applies a cooldown. Extracted from ``pool_ops.py`` during the t2069
decomposition.

Env: POOL_FILE_PATH, AUTH_FILE_PATH, PROVIDER, REASON, RETRY_SECONDS
"""

from __future__ import annotations

import json
import os
import sys
import time
from datetime import datetime, timezone

from ._common import acquire_lock, atomic_write_json, release_lock


_REASON_TO_STATUS = {
    "rate_limit": "rate-limited",
    "auth_error": "auth-error",
    "provider_error": "rate-limited",
}


def _find_index_by_access(accounts: list[dict], current_access: str) -> int:
    if not current_access:
        return -1
    for i, acct in enumerate(accounts):
        if acct.get("access", "") == current_access:
            return i
    return -1


def _find_index_by_openai_account_id(accounts: list[dict], account_id: str) -> int:
    if not account_id:
        return -1
    for i, acct in enumerate(accounts):
        if acct.get("accountId", "") == account_id:
            return i
    return -1


def _find_index_by_most_recent(accounts: list[dict]) -> int:
    """Pick the account with the most recent ``lastUsed`` timestamp.

    Mirrors the pre-refactor fallback: ties go to the LATER index because the
    comparison uses ``>=``. Always returns 0 when the list is non-empty.
    """
    best_i = 0
    best_last = ""
    for i, acct in enumerate(accounts):
        last = acct.get("lastUsed", "")
        if last >= best_last:
            best_last = last
            best_i = i
    return best_i


def _resolve_failed_index(accounts: list[dict], current_auth: dict, provider: str) -> int:
    """Resolve which account failed via 3 fallback strategies.

    1. Match by current access token in ``auth.json``
    2. (OpenAI only) Match by ``accountId``
    3. Most-recently-used account
    """
    current_access = current_auth.get("access", "")
    idx = _find_index_by_access(accounts, current_access)
    if idx >= 0:
        return idx
    if provider == "openai":
        idx = _find_index_by_openai_account_id(accounts, current_auth.get("accountId", ""))
        if idx >= 0:
            return idx
    return _find_index_by_most_recent(accounts)


def _apply_failure_to_account(
    account: dict,
    target_status: str,
    retry_seconds: int,
    now_ms: int,
) -> int:
    """Apply status, cooldown, and lastUsed to an account in place.

    Returns the cooldown timestamp so the caller can include it in output.
    """
    cooldown_until = now_ms + retry_seconds * 1000
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    account["status"] = target_status
    account["cooldownUntil"] = cooldown_until
    account["lastUsed"] = now_iso
    return cooldown_until


def cmd_mark_failure() -> None:
    pool_path = os.environ["POOL_FILE_PATH"]
    auth_path = os.environ["AUTH_FILE_PATH"]
    provider = os.environ["PROVIDER"]
    reason = os.environ["REASON"]
    retry_seconds = int(os.environ["RETRY_SECONDS"])

    target_status = _REASON_TO_STATUS.get(reason, "rate-limited")

    lock_path = pool_path + ".lock"
    lock_fd = open(lock_path, "w")
    try:
        acquire_lock(lock_fd)
        with open(pool_path) as f:
            pool = json.load(f)
        with open(auth_path) as f:
            auth = json.load(f)

        accounts = pool.get(provider, [])
        if not accounts:
            print("SKIP:no_accounts")
            sys.exit(0)

        current_auth = auth.get(provider, {}) if isinstance(auth, dict) else {}
        idx = _resolve_failed_index(accounts, current_auth, provider)

        now_ms = int(time.time() * 1000)
        target = accounts[idx]
        cooldown_until = _apply_failure_to_account(target, target_status, retry_seconds, now_ms)
        pool[provider] = accounts

        atomic_write_json(pool_path, pool)
        email = target.get("email", "unknown")
        print(f"OK:{email}:{target_status}:{cooldown_until}")
    finally:
        release_lock(lock_fd)
        lock_fd.close()
