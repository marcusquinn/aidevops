#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
oauth-pool-lib/pool_ops_entry_sync.py — single-entry get/put/fingerprint ops.

Backs ``oauth-pool-helper.sh remote-sync``. Moves ONE pool account between two
pools over stdin/stdout so a rotated refresh token is never forked:

  entry-get          print the account JSON (empty output when absent)
  entry-put          read an account JSON from stdin; write it only when its
                     ``expires`` is newer than the stored one; always print the
                     winning entry (empty when none) so a pipeline can sync back
  entry-fingerprint  print sha256 prefixes + expires, never token bytes

Env: POOL_FILE_PATH, PROVIDER, EMAIL, ORG (optional orgId prefix or org name).
Status words go to stderr. Identity is the seat (email + optional orgId,
GH#38959): when an email has several seats and ORG does not pick one, every
op refuses with ``ambiguous-seat`` (exit 2) rather than syncing the wrong seat.
Other providers/accounts in the pool are never touched. Writes take the shared
``oauth-pool.json.lock.d`` lock and use the atomic 600-perm writer.
"""

from __future__ import annotations

import hashlib
import json
import os
import sys

from ._common import acquire_lock, atomic_write_json, pool_account_key, release_lock, select_seat


def _accounts(pool: dict, provider: str) -> list:
    accounts = pool.get(provider, [])
    return accounts if isinstance(accounts, list) else []


def _ambiguous() -> None:
    print("ambiguous-seat: this email has several seats; pass --org <orgId-prefix|org name>",
          file=sys.stderr)
    sys.exit(2)


def _find(pool: dict, provider: str, email: str, org: str = "") -> dict | None:
    accounts = _accounts(pool, provider)
    idx, error, _seats = select_seat(accounts, email, org)
    if error == "ambiguous":
        _ambiguous()
    return accounts[idx] if idx >= 0 else None


def _find_for_incoming(pool: dict, provider: str, incoming: dict, org: str) -> dict | None:
    """Resolve the local seat an incoming entry merges into.

    An org-tagged entry matches its exact seat key; failing that it adopts the
    email's single legacy seat with no orgId (the same upgrade path as upsert),
    else it is a new seat. An entry with no orgId uses the ORG selector rules.
    """
    org_id = incoming.get("orgId") or ""
    if not org_id:
        return _find(pool, provider, incoming["email"], org)
    accounts = _accounts(pool, provider)
    key = pool_account_key(incoming)
    exact = next((a for a in accounts if isinstance(a, dict) and pool_account_key(a) == key), None)
    if exact is not None:
        return exact
    legacy = [a for a in accounts if isinstance(a, dict)
              and a.get("email") == incoming["email"] and not a.get("orgId")]
    return legacy[0] if len(legacy) == 1 else None


def _load(pool_path: str) -> dict:
    """Load the pool; only a missing file is an empty pool (never clobber others)."""
    try:
        with open(pool_path, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:
        print(f"pool-unreadable: {exc.__class__.__name__}", file=sys.stderr)
        sys.exit(1)
    if not isinstance(data, dict):
        print("pool-unreadable: root is not an object", file=sys.stderr)
        sys.exit(1)
    return data


def _num(value: object) -> float:
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else 0


def _expires(account: dict | None) -> int:
    value = account.get("expires", 0) if account else 0
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else 0


def _emit(account: dict | None) -> None:
    if account:
        json.dump(account, sys.stdout)
        sys.stdout.write("\n")


def cmd_entry_get() -> None:
    pool = _load(os.environ["POOL_FILE_PATH"])
    _emit(_find(pool, os.environ["PROVIDER"], os.environ["EMAIL"], os.environ.get("ORG", "")))


def _clear_failure_state(account: dict) -> None:
    for key in [k for k in account if k.startswith("authFailures") or k.startswith("authRefreshFailures")]:
        account.pop(key, None)
    if account.get("status") in (None, "auth-error"):
        account["status"] = "active"


def _apply_incoming(pool: dict, provider: str, incoming: dict, org: str) -> tuple[str, dict]:
    """Merge ``incoming`` into ``pool`` in place; return (status word, seat)."""
    existing = _find_for_incoming(pool, provider, incoming, org)
    if existing is None:
        entry = dict(incoming)
        _clear_failure_state(entry)
        entry["status"] = entry.get("status") or "active"
        accounts = pool.get(provider)
        if not isinstance(accounts, list):
            accounts = pool[provider] = []
        accounts.append(entry)
        return "inserted", entry
    if _expires(incoming) <= _expires(existing):
        return "unchanged", existing
    # Adopt the newer entry; keep local-only fields (e.g. priority) it lacks.
    carried_cooldown = max(_num(existing.get("cooldownUntil")), _num(incoming.get("cooldownUntil")))
    existing.update(incoming)
    if carried_cooldown:
        existing["cooldownUntil"] = carried_cooldown
    _clear_failure_state(existing)
    return "updated", existing


def _invalid() -> None:
    print("invalid-input", file=sys.stderr)
    sys.exit(1)


def _read_incoming(email: str) -> dict | None:
    raw = sys.stdin.read().strip()
    if not raw:
        return None
    try:
        incoming = json.loads(raw)
    except ValueError:
        _invalid()
    if not isinstance(incoming, dict) or incoming.get("email") != email:
        _invalid()
    if not incoming.get("refresh") or not incoming.get("access"):
        _invalid()
    return incoming


def cmd_entry_put() -> None:
    pool_path = os.environ["POOL_FILE_PATH"]
    provider = os.environ["PROVIDER"]
    email = os.environ["EMAIL"]
    org = os.environ.get("ORG", "")
    incoming = _read_incoming(email)

    lock_fd = None
    try:
        if incoming is not None:
            os.makedirs(os.path.dirname(pool_path) or ".", mode=0o700, exist_ok=True)
            lock_fd = open(pool_path + ".lock", "a")
            acquire_lock(lock_fd)
        pool = _load(pool_path)
        if incoming is None:
            print("noop", file=sys.stderr)
            _emit(_find(pool, provider, email, org))
            return
        status, seat = _apply_incoming(pool, provider, incoming, org)
        if status != "unchanged":
            atomic_write_json(pool_path, pool)
        print(status, file=sys.stderr)
        _emit(seat)
    finally:
        if lock_fd is not None:
            release_lock(lock_fd)
            lock_fd.close()


def _fp(value: object) -> str:
    if not isinstance(value, str) or not value:
        return "-"
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]


def cmd_entry_fingerprint() -> None:
    pool = _load(os.environ["POOL_FILE_PATH"])
    account = _find(pool, os.environ["PROVIDER"], os.environ["EMAIL"], os.environ.get("ORG", ""))
    if account is None:
        print("absent")
        return
    print(
        f"refresh={_fp(account.get('refresh'))} access={_fp(account.get('access'))} "
        f"expires={_expires(account)} status={account.get('status', '-')}"
    )
