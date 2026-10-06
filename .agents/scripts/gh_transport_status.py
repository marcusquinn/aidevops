# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Read-only local REST admission diagnostics (no credentials, HTTP or writes)."""

import json
import sqlite3
import time
from pathlib import Path

LIVE_WINDOWS = "live-windows.json"


def _live_window_is_newer(directory: Path, scope: str, stored_reset: float) -> bool:
    try:
        data = json.loads((directory / LIVE_WINDOWS).read_text(encoding="utf-8"))
        return int(data[f"{scope}:core"]["reset"]) > stored_reset
    except (OSError, ValueError, KeyError, TypeError):
        return False


def _read_root(db, scope: str) -> str:
    for _ in range(256):
        alias = db.execute("SELECT target FROM alias WHERE scope=?", (scope,)).fetchone()
        if not alias:
            return scope
        scope = alias[0]
    raise ValueError("quota scope alias cycle")


def _scope_diagnostics(db, requested_scope: str, scope: str, attributed: bool) -> tuple[int, dict]:
    bindings = sum(_read_root(db, binding[0]) == scope for binding in
                   db.execute("SELECT scope FROM binding").fetchall())
    ambiguity = None
    if attributed and requested_scope != scope:
        ambiguity = "configured_owner_requires_reconciliation"
    elif not attributed and bindings > 1:
        ambiguity = "unresolved_scope_has_multiple_credentials"
    diagnostics = {"scope_mode": "configured" if attributed else "unresolved",
                   "bound_credentials": bindings, "ambiguity": ambiguity}
    if ambiguity:
        diagnostics["reconcile_command"] = (
            "python3 .agents/scripts/gh_transport_budget.py reconcile"
        )
    return bindings, diagnostics


def _state_for(row, reserved: int, now: float) -> str:
    if row[3] > now:
        return "cooldown"
    if row[1] <= now or row[2] > now:
        return "unknown"
    if row[0] - reserved <= 0:
        return "exhausted"
    return "available"


def admission_status(directory: Path, scope: str, *, attributed: bool = False) -> dict:
    """Read local core admission evidence without credentials, HTTP or mutations."""
    path = directory / "admission.sqlite3"
    if not path.is_file() or path.is_symlink():
        return {"state": "unknown"}
    db = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=2)
    try:
        requested_scope = scope
        try:
            scope = _read_root(db, scope)
        except ValueError:
            return {"state": "unknown"}
        bindings, diagnostics = _scope_diagnostics(db, requested_scope, scope, attributed)
        row = db.execute(
            "SELECT remaining,reset,observed,blocked_until,quota_limit FROM quota "
            "WHERE scope=? AND resource='core'", (scope,),
        ).fetchone()
        if not row:
            return {"state": "unknown", **diagnostics}
        if bindings > 1 and _live_window_is_newer(directory, scope, row[1]):
            diagnostics["stale_multi_credential_scope"] = True
            diagnostics["stale_scope_note"] = (
                "stored reset is older than a live observation from another bound credential"
            )
        reserved = db.execute(
            "SELECT COUNT(*) FROM reservation WHERE scope=? AND resource='core'", (scope,),
        ).fetchone()[0]
        now = time.time()
        return {"state": _state_for(row, reserved, now), "source": "local_response_headers",
                **diagnostics, "remaining": row[0],
                "limit": row[4], "reserved": reserved, "floor": 0,
                "blocked_until": row[3],
                "reset": int(row[1]), "observation_age_seconds": max(0, int(now - row[2]))}
    finally:
        db.close()
