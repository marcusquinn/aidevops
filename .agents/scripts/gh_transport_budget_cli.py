# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Command-line interface for GitHub transport admission state."""

import json
import sqlite3
import sys
import time
from pathlib import Path

from gh_transport_budget import (
    Deferred,
    credential_identity,
    private_directory,
    quota_owner,
    reconcile_scope,
    scope_key,
)
from gh_transport_identity import (
    configure_owner,
    credentials_share_proven_owner,
    resolve_owner_proof,
    state_directory,
)
from gh_transport_recovery import admission_status
from gh_transport_schema import live_binding_credentials
from gh_transport_status import _read_root

COMMANDS = ("status", "reconcile", "set-owner")


def _live_unresolved_credentials(directory: Path) -> list:
    """Credentials still live in the unresolved scope (fingerprints only)."""
    path = directory / "admission.sqlite3"
    if not path.is_file() or path.is_symlink():
        return []
    db = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=2)
    try:
        scope = _read_root(db, scope_key("github.com", "unresolved"))
        return live_binding_credentials(db, scope, lambda bound: _read_root(db, bound), time.time())
    finally:
        db.close()


def set_owner(directory: Path) -> dict:
    """Persist the authenticated login's digest as this host's quota owner."""
    host = "github.com"
    credential, authenticated, environment = credential_identity("gh", host)
    if not authenticated:
        raise ValueError("authenticate gh before configuring a quota owner")
    private_directory(directory)
    owner = resolve_owner_proof(("gh", host), credential, environment, directory)
    if not owner:
        raise ValueError("owner proof unavailable; installation tokens are never attributed")
    # Every live binding must be proven to be this login. A live ghs_ token or
    # unproven credential may be another allowance, so it is never merged.
    live = _live_unresolved_credentials(directory)
    if not credentials_share_proven_owner(directory, [credential, *live]):
        raise ValueError("live bindings are not all proven to be this login; "
                         "retry after retired bindings age out")
    return {"state": configure_owner(directory, owner),
            "next": "stop local GitHub requests, then run gh_transport_budget.py reconcile"}


def _run(command: str, directory: Path) -> dict:
    if command == "set-owner":
        return set_owner(directory)
    owner, attributed = quota_owner(directory)
    if command == "status":
        return admission_status(directory, scope_key("github.com", owner), attributed=attributed)
    if not attributed:
        raise ValueError("run gh_transport_budget.py set-owner before reconciliation")
    return reconcile_scope(directory, scope_key("github.com", "unresolved"),
                           scope_key("github.com", owner))


def main() -> None:
    """Report admission status, configure the owner or reconcile attributed state."""
    if sys.argv[1:] not in [[name] for name in COMMANDS]:
        raise SystemExit(2)
    command = sys.argv[1]
    try:
        print(json.dumps(_run(command, state_directory())))
    except Deferred as exc:
        print(json.dumps({"state": "blocked", "reason": str(exc)}))
        raise SystemExit(75)
    except (OSError, ValueError, sqlite3.Error) as exc:
        if command != "status":
            print(json.dumps({"state": "error", "reason": str(exc)}))
            raise SystemExit(2)
        print('{"state":"unknown"}')
