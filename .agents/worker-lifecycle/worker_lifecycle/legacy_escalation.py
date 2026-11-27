"""Terminal journal entry for a structurally half-removed legacy worktree."""

from __future__ import annotations

from pathlib import Path

from .interrupted_removal import half_removed
from .legacy_options import half_state_outcome, preservation_name
from .legacy_probe import checkpoint, operation_id, receipt
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
