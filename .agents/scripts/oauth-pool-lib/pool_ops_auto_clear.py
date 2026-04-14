#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
oauth-pool-lib/pool_ops_auto_clear.py — auto-clear command implementation.

Atomically clears expired cooldowns from the pool file. Extracted from the
monolithic ``pool_ops.py`` during the t2069 decomposition; the pool_ops
facade re-dispatches ``auto-clear`` here.

Env: POOL_FILE_PATH
"""

from __future__ import annotations

import json
import os
import time

from ._common import acquire_lock, atomic_write_json, release_lock


def _is_account_list(value) -> bool:
    return isinstance(value, list)


def _clear_expired_cooldown(account: dict, now_ms: int) -> bool:
    """Clear an expired cooldown on a single account.

    Returns True if the account was modified. Status is only cleared from
    ``rate-limited`` to ``idle``; other statuses (e.g. ``auth-error``) keep
    their status but lose their cooldown timestamp, matching the pre-refactor
    behaviour.
    """
    cd = account.get("cooldownUntil")
    if not (cd and isinstance(cd, (int, float)) and cd > 0 and cd <= now_ms):
        return False
    if account.get("status") == "rate-limited":
        account["status"] = "idle"
    account["cooldownUntil"] = 0
    return True


def _clear_expired_in_pool(pool: dict, now_ms: int) -> bool:
    """Walk every provider's accounts and clear expired cooldowns in place."""
    changed = False
    for provider in list(pool.keys()):
        if provider.startswith("_"):
            continue
        accounts = pool.get(provider, [])
        if not _is_account_list(accounts):
            continue
        for acct in accounts:
            if _clear_expired_cooldown(acct, now_ms):
                changed = True
    return changed


def cmd_auto_clear() -> None:
    pool_path = os.environ["POOL_FILE_PATH"]
    lock_path = pool_path + ".lock"
    lock_fd = open(lock_path, "w")
    try:
        acquire_lock(lock_fd)
        with open(pool_path) as f:
            pool = json.load(f)

        now_ms = int(time.time() * 1000)
        if _clear_expired_in_pool(pool, now_ms):
            atomic_write_json(pool_path, pool)
            print("CHANGED")
        else:
            print("UNCHANGED")
    finally:
        release_lock(lock_fd)
        lock_fd.close()
