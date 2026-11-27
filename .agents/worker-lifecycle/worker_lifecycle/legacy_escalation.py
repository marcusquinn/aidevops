"""Terminal journal entry for a structurally half-removed legacy worktree."""

from __future__ import annotations

from pathlib import Path

from .interrupted_removal import half_removed
from .legacy_options import half_state_outcome, preservation_name
from .legacy_options import require_manual_confirmation
from .legacy_probe import checkpoint, operation_id, receipt
from .legacy_resume import RECONSTRUCTIBLE_REMOVING
from .retirement import _lock


def escalate_half_state(store, item, code, apply):
    """Journal one terminal half-removal report; this grants no removal authority.

    The registry write is the escalation: later passes report the same structure as
    already escalated instead of re-deciding it as a fresh retry (GH#40569).
    """
    if not apply:
        return "needs-resume"
    operation = operation_id(store, item["path"])
    with _lock(store, operation), store.connection(write=True) as connection:
        if receipt(connection, operation, "half-removed") is None:
            checkpoint(store, connection, operation, "half-removed",
                       {"type": "legacy-worktree-half-removed", "reason": code,
                        "structural": True})
            return "needs-resume"
    return "already-escalated"


def half_state_report(store, item, journaled, apply):
    """Return a terminal outcome for an unjournaled half-removed tree, else None.

    A journaled removal owns the half-state it produced. Operator-preserved names
    keep their existing exclusion and are never escalated this way (GH#40569).
    """
    if journaled or preservation_name(item["path"]):
        return None
    code = half_removed(Path(item["path"]))
    if not code:
        return None
    status = escalate_half_state(store, item, code, apply)
    return {"path": item["path"], **half_state_outcome(item, code, status)}


def require_confirmation(connection, operation, confirmed):
    """An interrupted capture carries manual authority before a plan exists."""
    require_manual_confirmation(
        (receipt(connection, operation, phase) for phase in ("archive", "plan")),
        confirmed,
    )


def item_state(store, item, confirmed):
    """Return the operation id and its retired, plan and removing receipts."""
    operation = operation_id(store, item["path"])
    with store.connection() as connection:
        done = receipt(connection, operation, "retired")
        pending = receipt(connection, operation, "plan")
        removing = receipt(connection, operation, RECONSTRUCTIBLE_REMOVING)
        if not done:
            require_confirmation(connection, operation, confirmed)
    return operation, done, pending, removing
