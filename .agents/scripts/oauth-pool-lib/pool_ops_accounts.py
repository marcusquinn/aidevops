#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
oauth-pool-lib/pool_ops_accounts.py — account CRUD command implementations.

Pool/account management commands that read pool JSON from stdin and write
the updated pool to stdout. Extracted from ``pool_ops.py`` during the t2069
decomposition.
"""

from __future__ import annotations

import json
import os
import sys


def cmd_upsert() -> None:
    """upsert: Upsert an account into the pool.

    Env: PROVIDER, EMAIL, ACCESS, REFRESH, EXPIRES, NOW_ISO, ACCOUNT_ID
    """
    pool = json.load(sys.stdin)
    provider = os.environ["PROVIDER"]
    email = os.environ["EMAIL"]
    access = os.environ["ACCESS"]
    refresh = os.environ["REFRESH"]
    expires = int(os.environ["EXPIRES"])
    now_iso = os.environ["NOW_ISO"]
    account_id = os.environ.get("ACCOUNT_ID", "")

    if provider not in pool:
        pool[provider] = []

    found = False
    for account in pool[provider]:
        if account.get("email") == email:
            account["access"] = access
            account["refresh"] = refresh
            account["expires"] = expires
            account["lastUsed"] = now_iso
            account["status"] = "active"
            account["cooldownUntil"] = None
            if account_id:
                account["accountId"] = account_id
            found = True
            break

    if not found:
        entry = {
            "email": email,
            "access": access,
            "refresh": refresh,
            "expires": expires,
            "added": now_iso,
            "lastUsed": now_iso,
            "status": "active",
            "cooldownUntil": None,
        }
        if account_id:
            entry["accountId"] = account_id
        pool[provider].append(entry)

    json.dump(pool, sys.stdout, indent=2)


def cmd_set_priority() -> None:
    """set-priority: Set priority on an account.

    Env: PROVIDER, EMAIL, PRIORITY
    """
    pool = json.load(sys.stdin)
    provider = os.environ["PROVIDER"]
    email = os.environ["EMAIL"]
    priority = int(os.environ["PRIORITY"])

    accounts = pool.get(provider, [])
    idx = next((i for i, a in enumerate(accounts) if a.get("email") == email), -1)
    if idx < 0:
        print("ERROR:not_found")
        sys.exit(0)

    if priority == 0:
        accounts[idx].pop("priority", None)
    else:
        accounts[idx]["priority"] = priority
    json.dump(pool, sys.stdout, indent=2)


def cmd_remove_account() -> None:
    """remove-account: Remove an account from pool.

    Env: PROVIDER, EMAIL
    """
    pool = json.load(sys.stdin)
    provider = os.environ["PROVIDER"]
    email = os.environ["EMAIL"]

    if provider not in pool:
        print(json.dumps(pool, indent=2))
        sys.exit(1)

    original_count = len(pool[provider])
    pool[provider] = [a for a in pool[provider] if a.get("email") != email]
    new_count = len(pool[provider])

    if original_count == new_count:
        print(json.dumps(pool, indent=2))
        sys.exit(1)

    json.dump(pool, sys.stdout, indent=2)


def cmd_assign_pending() -> None:
    """assign-pending: Assign pending token to account.

    Env: PROVIDER, EMAIL
    """
    pool = json.load(sys.stdin)
    provider = os.environ["PROVIDER"]
    email = os.environ["EMAIL"]
    pending_key = "_pending_" + provider
    pending = pool.get(pending_key)

    if not pending:
        print("ERROR:no_pending")
        sys.exit(0)

    accounts = pool.get(provider, [])
    idx = next((i for i, a in enumerate(accounts) if a.get("email") == email), -1)
    if idx < 0:
        print("ERROR:not_found")
        sys.exit(0)

    accounts[idx]["refresh"] = pending.get("refresh", accounts[idx].get("refresh", ""))
    accounts[idx]["access"] = pending.get("access", accounts[idx].get("access", ""))
    accounts[idx]["expires"] = pending.get("expires", accounts[idx].get("expires", 0))
    accounts[idx]["status"] = "active"
    accounts[idx]["cooldownUntil"] = None
    del pool[pending_key]
    json.dump(pool, sys.stdout, indent=2)


def cmd_check_pending() -> None:
    """check-pending: Check if pending token exists.

    Env: PROVIDER
    """
    pool = json.load(sys.stdin)
    provider = os.environ["PROVIDER"]
    pending = pool.get("_pending_" + provider)
    if pending:
        print("FOUND:" + pending.get("added", "unknown"))
    else:
        print("NONE")


def cmd_list_pending() -> None:
    """list-pending: List accounts for pending assignment.

    Env: PROVIDER
    """
    pool = json.load(sys.stdin)
    provider = os.environ["PROVIDER"]
    for i, a in enumerate(pool.get(provider, []), 1):
        print(f'  {i}. {a["email"]}')


def cmd_import_check() -> None:
    """import-check: Check if email exists in pool.

    Env: EMAIL
    """
    pool = json.load(sys.stdin)
    email = os.environ["EMAIL"]
    for acc in pool.get("anthropic", []):
        if acc.get("email") == email:
            print("yes")
            sys.exit(0)
    print("no")


def cmd_status_stats() -> None:
    """status-stats: Print pool statistics.

    Env: NOW_MS, PROV
    """
    pool = json.load(sys.stdin)
    now = int(os.environ["NOW_MS"])
    prov = os.environ["PROV"]
    accounts = pool.get(prov, [])

    total = len(accounts)
    available = sum(1 for a in accounts if not a.get("cooldownUntil") or a["cooldownUntil"] <= now)
    active = sum(1 for a in accounts if a.get("status") in ("active", "idle"))
    rate_lim = sum(
        1 for a in accounts if a.get("status") == "rate-limited" and a.get("cooldownUntil", 0) > now
    )
    auth_err = sum(1 for a in accounts if a.get("status") == "auth-error")

    print(f"{prov} pool:")
    print(f"  Total accounts : {total}")
    print(f"  Available now  : {available}")
    print(f"  Active/idle    : {active}")
    print(f"  Rate limited   : {rate_lim}")
    print(f"  Auth errors    : {auth_err}")
    if available == 0 and total > 0:
        print("  WARNING: no accounts available — run reset-cooldowns or add an account")


def cmd_list_accounts() -> None:
    """list-accounts: List accounts with status.

    Env: PROVIDER
    """
    pool = json.load(sys.stdin)
    prov = os.environ["PROVIDER"]
    for i, a in enumerate(pool.get(prov, []), 1):
        status = a.get("status", "unknown")
        email = a.get("email", "unknown")
        priority = a.get("priority")
        priority_str = f" priority:{priority}" if priority is not None else ""
        print(f"  {i}. {email} [{status}]{priority_str}")
