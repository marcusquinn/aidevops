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

from ._common import pool_account_label, select_seat
from ._seat_upsert import (
    apply_grant_identity,
    print_ambiguous,
    report_upsert_note,
    select_or_report,
    upsert_target,
)


def cmd_upsert() -> None:
    """upsert: Upsert an account into the pool.

    Env: PROVIDER, EMAIL, ACCESS, REFRESH, EXPIRES, NOW_ISO, ACCOUNT_ID,
    ORG_ID, ORG_NAME (optional Anthropic organization; GH#38959),
    LEGACY_ORG_ID, LEGACY_ORG_NAME (optional org resolved for the email's
    single legacy no-org seat, so a different-org grant adds a seat)

    Identity is email + optional orgId: the same seat is updated, a new org
    for the same email adds a seat. A grant without org for an email with
    several seats is refused (exit 3, nothing on stdout) so the caller never
    saves a guessed overwrite.
    """
    pool = json.load(sys.stdin)
    provider = os.environ["PROVIDER"]
    email = os.environ["EMAIL"]
    access = os.environ["ACCESS"]
    refresh = os.environ["REFRESH"]
    expires = int(os.environ["EXPIRES"])
    now_iso = os.environ["NOW_ISO"]
    account_id = os.environ.get("ACCOUNT_ID", "")
    org_id = os.environ.get("ORG_ID", "").strip()
    org_name = os.environ.get("ORG_NAME", "").strip()

    if provider not in pool:
        pool[provider] = []

    legacy_org = (os.environ.get("LEGACY_ORG_ID", "").strip(),
                  os.environ.get("LEGACY_ORG_NAME", "").strip())
    idx, note = upsert_target(pool[provider], email, org_id, legacy_org)
    if note == "ambiguous":
        print(f"ERROR: {email} has several {provider} seats and this grant carries no "
              "organization, so the target seat is unknown. Nothing was saved.", file=sys.stderr)
        sys.exit(3)

    if idx >= 0:
        account = pool[provider][idx]
        account["access"] = access
        account["refresh"] = refresh
        account["expires"] = expires
        account["lastUsed"] = now_iso
        account["status"] = "active"
        account["cooldownUntil"] = None
    else:
        account = {
            "email": email,
            "access": access,
            "refresh": refresh,
            "expires": expires,
            "added": now_iso,
            "lastUsed": now_iso,
            "status": "active",
            "cooldownUntil": None,
        }
        pool[provider].append(account)
    apply_grant_identity(account, account_id, org_id, org_name)
    report_upsert_note(note, email, account)

    json.dump(pool, sys.stdout, indent=2)


def cmd_set_priority() -> None:
    """set-priority: Set priority on one seat.

    Env: PROVIDER, EMAIL, PRIORITY, ORG (optional orgId prefix or org name)
    """
    pool = json.load(sys.stdin)
    provider = os.environ["PROVIDER"]
    email = os.environ["EMAIL"]
    priority = int(os.environ["PRIORITY"])

    accounts = pool.get(provider, [])
    idx = select_or_report(accounts, email, os.environ.get("ORG", ""))
    if idx < 0:
        sys.exit(0)

    if priority == 0:
        accounts[idx].pop("priority", None)
    else:
        accounts[idx]["priority"] = priority
    json.dump(pool, sys.stdout, indent=2)


def cmd_remove_account() -> None:
    """remove-account: Remove one seat from the pool.

    Env: PROVIDER, EMAIL, ORG (optional orgId prefix or org name)
    Exit 1 when not found; exit 2 with the ambiguity protocol on stdout when
    the email has several seats and ORG does not pick one.
    """
    pool = json.load(sys.stdin)
    provider = os.environ["PROVIDER"]
    email = os.environ["EMAIL"]

    if provider not in pool:
        print(json.dumps(pool, indent=2))
        sys.exit(1)

    idx, error, seats = select_seat(pool[provider], email, os.environ.get("ORG", ""))
    if error == "ambiguous":
        print_ambiguous(seats)
        sys.exit(2)
    if idx < 0:
        print(json.dumps(pool, indent=2))
        sys.exit(1)

    del pool[provider][idx]
    json.dump(pool, sys.stdout, indent=2)


def cmd_assign_pending() -> None:
    """assign-pending: Assign pending token to one seat.

    Env: PROVIDER, EMAIL, ORG (optional orgId prefix or org name)
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
    idx = select_or_report(accounts, email, os.environ.get("ORG", ""))
    if idx < 0:
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
        print(f'  {i}. {pool_account_label(a)}')


def cmd_import_check() -> None:
    """import-check: Check whether the Claude CLI login already has a seat.

    Env: EMAIL, ORG_ID (optional; the CLI login's organization). With ORG_ID,
    only that seat or an email-only legacy seat (org unknown) counts, so a
    different organization's seat on the same email can still be imported
    (GH#38959).
    """
    pool = json.load(sys.stdin)
    email = os.environ["EMAIL"]
    org_id = os.environ.get("ORG_ID", "").strip()
    for acc in pool.get("anthropic", []):
        if acc.get("email") != email:
            continue
        if not org_id or not acc.get("orgId") or acc.get("orgId") == org_id:
            print("yes")
            sys.exit(0)
    print("no")


def _is_status_available(account: dict, now_ms: int) -> bool:
    """Effective dispatch eligibility for status reporting.

    An ``auth-error`` account is never available, whatever its cooldown:
    expiry only makes it eligible for refresh re-validation, and rotation
    (``pool_ops_rotate._is_immediately_available``) and Pulse capacity
    (``pulse-capacity.sh::_pulse_capacity_provider_account_counts``) both
    exclude it. Every other account is available once its cooldown is
    missing, null, zero or expired.
    """
    if account.get("status") == "auth-error":
        return False
    cooldown = account.get("cooldownUntil") or 0
    return cooldown <= now_ms


def cmd_status_stats() -> None:
    """status-stats: Print pool statistics.

    Env: NOW_MS, PROV
    """
    pool = json.load(sys.stdin)
    now = int(os.environ["NOW_MS"])
    prov = os.environ["PROV"]
    accounts = pool.get(prov, [])

    total = len(accounts)
    available = sum(1 for a in accounts if _is_status_available(a, now))
    active = sum(1 for a in accounts if a.get("status") in ("active", "idle"))
    rate_lim = sum(
        1
        for a in accounts
        if a.get("status") == "rate-limited" and (a.get("cooldownUntil") or 0) > now
    )
    auth_err = sum(1 for a in accounts if a.get("status") == "auth-error")

    print(f"{prov} pool:")
    print(f"  Total accounts : {total}")
    print(f"  Available now  : {available}")
    print(f"  Active/idle    : {active}")
    print(f"  Rate limited   : {rate_lim}")
    print(f"  Auth errors    : {auth_err}")
    if available == 0 and total > 0:
        if auth_err > 0:
            # reset-cooldowns marks auth-error accounts idle without
            # validating credentials, so it must not be the recovery advice.
            print(
                "  WARNING: no accounts available — auth-error accounts need re-authentication: "
                "run check, or re-add the account (reset-cooldowns does not validate credentials)"
            )
        else:
            print("  WARNING: no accounts available — run reset-cooldowns or add an account")


def cmd_list_accounts() -> None:
    """list-accounts: List accounts with status.

    Env: PROVIDER
    """
    pool = json.load(sys.stdin)
    prov = os.environ["PROVIDER"]
    for i, a in enumerate(pool.get(prov, []), 1):
        status = a.get("status", "unknown")
        label = pool_account_label(a)
        priority = a.get("priority")
        priority_str = f" priority:{priority}" if priority is not None else ""
        print(f"  {i}. {label} [{status}]{priority_str}")
