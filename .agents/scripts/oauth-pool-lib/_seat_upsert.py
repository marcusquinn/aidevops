#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
oauth-pool-lib/_seat_upsert.py — seat targeting for pool_ops_accounts.py.

A seat is email + optional Anthropic orgId (GH#38959). These helpers decide
which row an incoming grant updates and print the shared selection protocol
(``ERROR:ambiguous`` / ``ERROR:not_found``). Mirrors findUpsertTarget() in
oauth-pool-storage.mjs.
"""

from __future__ import annotations

import sys

from ._common import pool_account_key, pool_account_label, select_seat


def print_ambiguous(seats: list[dict]) -> None:
    """Print the ambiguity marker plus one candidate seat label per line."""
    print("ERROR:ambiguous")
    for seat in seats:
        print(f"  {pool_account_label(seat)}")


def select_or_report(accounts: list, email: str, org: str) -> int:
    """Return the selected seat index, or print the error protocol and -1."""
    idx, error, seats = select_seat(accounts, email, org)
    if error == "ambiguous":
        print_ambiguous(seats)
    elif error:
        print("ERROR:not_found")
    return idx


def _email_only_target(seats: list[int]) -> tuple[int, str]:
    """A grant without org updates the email's only seat; several is ambiguous."""
    if len(seats) > 1:
        return -1, "ambiguous"
    return (seats[0] if seats else -1), ""


def _legacy_seat_target(accounts: list, seats: list[int], org_id: str,
                        legacy_org: tuple[str, str]) -> tuple[int, str]:
    """A grant with org and one legacy no-org seat: split when that seat's
    resolved org differs (recording it on the legacy row), else update it."""
    legacy = [i for i in seats if not accounts[i].get("orgId")]
    if len(legacy) != 1:
        return -1, ""
    legacy_id, legacy_name = legacy_org
    if legacy_id and legacy_id != org_id:
        accounts[legacy[0]]["orgId"] = legacy_id
        if legacy_name:
            accounts[legacy[0]]["orgName"] = legacy_name
        return -1, "split"
    return legacy[0], ("" if legacy_id else "unresolved")


def upsert_target(accounts: list, email: str, org_id: str,
                  legacy_org: tuple[str, str] = ("", "")) -> tuple[int, str]:
    """Find the seat an incoming grant updates. Returns ``(index, note)``:
    index -1 adds a seat; note is ``""``, ``"ambiguous"`` (refuse), ``"split"``
    (the legacy no-org seat belongs to another org, now recorded on it) or
    ``"unresolved"`` (the legacy seat was updated in place, org unknown).
    ``legacy_org`` is the (orgId, orgName) resolved for that legacy seat."""
    key = f"{email}#{org_id}" if org_id else email
    exact = next((i for i, a in enumerate(accounts) if pool_account_key(a) == key), -1)
    if exact >= 0:
        return exact, ""
    seats = [i for i, a in enumerate(accounts) if a.get("email") == email]
    if org_id:
        return _legacy_seat_target(accounts, seats, org_id, legacy_org)
    return _email_only_target(seats)


def apply_grant_identity(account: dict, account_id: str, org_id: str, org_name: str) -> None:
    """Record the grant's provider account id and organization on the seat."""
    if account_id:
        account["accountId"] = account_id
    if org_id:
        account["orgId"] = org_id
        if org_name:
            account["orgName"] = org_name


def report_upsert_note(note: str, email: str, account: dict) -> None:
    """Explain a seat split or an unresolved legacy update on stderr."""
    label = pool_account_label(account)
    if note == "split":
        print(f"NOTE: {email} now has separate seats per organization; added "
              f"{label}.", file=sys.stderr)
    elif note == "unresolved":
        print(f"NOTE: {email} had one seat with no recorded organization, so it was updated "
              f"in place and now holds {label}. If that seat belonged to a different "
              "organization (e.g. Team vs Personal), re-add it now; it will be stored as a "
              "separate seat.", file=sys.stderr)
