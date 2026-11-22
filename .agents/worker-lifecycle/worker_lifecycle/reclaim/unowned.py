# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Evidence-backed authorization for a never-owned enrolled generation (GH#38405).

A tree enrolled without any registered run (for example by a producer outside a
declared runtime) cannot prove its owners ended, because it never had one. The
legacy answer was an ``operator_confirmed`` event; Reclaim replaces it with the
facts it checked, recorded as ``reclaim-unowned-authorized``:

- owner check: no run was ever bound and no ``created-worktree`` receipt exists;
- git state: nothing removal would lose (clean, and HEAD contained in a remote);
- the tree's references and its evidence fingerprint, re-taken after the git
  check so a change during the check refuses (compare-and-swap).

The predicate, event and admission closure share one writer transaction
(``AdmissionRegistry.close_unowned``). The event is keyed by generation, so a
replay re-checks the facts and then leaves the first authorization unchanged.
Retirement itself stays archive-first; this only replaces the confirmation.

Imports stay leaf-level: ``cleanup_plan`` reads this module, and
``reclaim.owners``/``reclaim.evidence`` import ``cleanup_plan``.
"""

from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
from uuid import UUID, uuid5

from ..admission import AdmissionClosed, AdmissionRegistry
from ..storage import LifecycleRegistry, StoreConflict
from .decision import fingerprint
from .host import EVIDENCE_CHANGED, nothing_to_lose

__all__ = ["UNOWNED_AUTHORIZED", "authorize", "unowned_authorized", "unowned_event_id"]

UNOWNED_AUTHORIZED = "reclaim-unowned-authorized"
NEVER_BOUND = "never-bound"
NOTHING_TO_LOSE = "nothing-to-lose"
# Upper bound for each git/fingerprint probe of the tree.
TIMEOUT = 60


def unowned_event_id(generation: str) -> str:
    """The idempotency key: one Reclaim authorization per generation."""
    return str(uuid5(UUID(generation), UNOWNED_AUTHORIZED))


def _payload(path: Path, generation: str, digest: str, references: list[str]) -> dict:
    return {
        "type": UNOWNED_AUTHORIZED, "schema": 1, "generation_id": generation,
        "path": str(path), "fingerprint": digest, "owner_check": NEVER_BOUND,
        "git_state": NOTHING_TO_LOSE, "references": list(references),
        "checked_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }


def _checked(path: Path) -> tuple[str | None, str]:
    """Return the evidence fingerprint when nothing would be lost, else the refusal.

    The fingerprint is re-taken after the git check, so a change during the
    check refuses (compare-and-swap).
    """
    digest = fingerprint(path, timeout=TIMEOUT)
    if digest is None:
        return None, "fingerprint-unavailable"
    clean, detail = nothing_to_lose(path, timeout=TIMEOUT)
    if not clean:
        return None, detail
    if fingerprint(path, timeout=TIMEOUT) != digest:
        return None, EVIDENCE_CHANGED
    return digest, ""


def authorize(store: LifecycleRegistry, path: Path, generation: str,
              references: list[str]) -> str | None:
    """Check the facts and journal the authorization; return None or the refusal.

    Every unreadable fact refuses. Admission stays open on any refusal, so a
    refused tree remains admissible and is never half-authorized.
    """
    digest, refusal = _checked(path)
    if digest is None:
        return refusal
    try:
        AdmissionRegistry(store).close_unowned(
            unowned_event_id(generation), generation,
            _payload(path, generation, digest, references))
    except (AdmissionClosed, StoreConflict) as error:
        return str(error)
    return None


def unowned_authorized(store: LifecycleRegistry, generation: str) -> bool:
    """True only for a closed generation Reclaim authorized and nothing ever owned."""
    with store.connection() as connection:
        event = connection.execute(
            "SELECT payload FROM events WHERE event_id=?",
            (unowned_event_id(generation),),
        ).fetchone()
        admission = connection.execute(
            "SELECT state FROM generation_admissions WHERE generation_id=?",
            (generation,),
        ).fetchone()
        bound = connection.execute(
            "SELECT 1 FROM bindings WHERE generation_id=?", (generation,),
        ).fetchone()
    if event is None or admission is None or bound is not None:
        return False
    try:
        payload = json.loads(event["payload"])
    except ValueError:
        return False
    if not isinstance(payload, dict):
        return False
    facts = tuple(payload.get(key) for key in
                  ("type", "schema", "generation_id", "owner_check", "git_state"))
    expected = (UNOWNED_AUTHORIZED, 1, generation, NEVER_BOUND, NOTHING_TO_LOSE)
    # Every fact the writer records must be present, not only the verdicts.
    recorded = all(isinstance(payload.get(key), str) and payload[key]
                   for key in ("fingerprint", "checked_at", "path"))
    return facts == expected and recorded and admission["state"] == "closed"
