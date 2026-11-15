# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Three-way reclaim decision, evidence fingerprint and journaled authorization.

``classify`` turns one evidence verdict into ``remove``, ``archive`` or
``refuse``. Finished work whose only blocker is local state that removal would
discard (uncommitted changes or unpushed commits) is ``archive``: it is queued
for the preserving archive stage rather than refused alongside unsafe trees.

An applied removal is journaled as evidence-backed authorization (GH#38348):
``reclaim-authorized`` before removal and ``reclaim-removed`` after, keyed by the
worktree path and an evidence fingerprint. Event IDs are derived from the full
canonical payload, so an identical repeated pass replays the same events instead
of appending new ones, while changed evidence never collides; removal
re-computes the fingerprint and refuses with ``evidence-changed`` on mismatch.
"""

from __future__ import annotations

from collections.abc import Callable
import hashlib
import os
from pathlib import Path
import sqlite3
from uuid import UUID, uuid5

from ..journal import append_event
from ..storage import LifecycleRegistry, StoreCapacity, StoreConflict, encode
from .host import EVIDENCE_CHANGED, git

__all__ = ["ARCHIVE", "ARCHIVED", "AUTHORIZED", "REFUSE", "REMOVE", "REMOVED", "cas_verify",
           "classify", "event_id", "fingerprint", "record"]

REMOVE = "remove"
ARCHIVE = "archive"
REFUSE = "refuse"
AUTHORIZED = "reclaim-authorized"
# Stage 2 (GH#38394): a verified archive of an ``archive`` tree, before removal.
ARCHIVED = "reclaim-archived"
REMOVED = "reclaim-removed"
EVENT_TYPES = (AUTHORIZED, ARCHIVED, REMOVED)
_UNPUSHED = "unpushed-commits-"


def _preservable(reason: str) -> bool:
    """Name local state an archive would keep; unreadable state never qualifies."""
    if reason == "uncommitted-changes":
        return True
    count = reason[len(_UNPUSHED):] if reason.startswith(_UNPUSHED) else ""
    return count.isdigit() and count != "0"


def classify(verdict: dict) -> tuple[str, str]:
    """Return ``(decision, reason)`` for one evidence verdict.

    Only an authorized verdict is ``remove``. ``archive`` additionally requires
    the evidence pass to have proved the work finished and every owner ended, so
    an open issue or a live owner always stays ``refuse``.
    """
    reason = str(verdict.get("reason", "unevaluated"))
    if verdict.get("authorized"):
        return REMOVE, reason
    if verdict.get("finished") and _preservable(reason):
        return ARCHIVE, reason
    return REFUSE, reason


Budget = Callable[[], int]


def fingerprint(path: Path, *, timeout: int = 60, remaining: Budget | None = None) -> str | None:
    """Hash the tree instance, HEAD, porcelain status and unpushed count.

    Any commit, checkout, edit or push between judgement and removal changes it,
    and so does replacing the directory: its device and inode identify this
    instance, so a tree recreated at the same path never inherits an earlier
    instance's journaled authorization. Returns None when anything is unreadable
    or ``remaining`` (the live pass budget) cannot cover the next command.
    """
    try:
        identity = os.lstat(path)
    except OSError:
        return None
    parts = [f"{identity.st_dev}:{identity.st_ino}"]
    for arguments in (("rev-parse", "--verify", "HEAD"),
                      ("status", "--porcelain", "-z", "--untracked-files=all",
                       "--ignore-submodules=none"),
                      ("rev-list", "--count", "HEAD", "--not", "--remotes")):
        budget = timeout if remaining is None else min(timeout, remaining())
        if budget < 1:
            return None
        status, output = git(path, *arguments, timeout=budget)
        if status != 0:
            return None
        parts.append(output)
    return hashlib.sha256("\0\0".join(parts).encode("utf-8")).hexdigest()


Verifier = Callable[[Path], "tuple[bool, str]"]


def cas_verify(expected: str, verify: Verifier, remaining: Budget | None = None) -> Verifier:
    """Wrap a removal-time verifier with the fingerprint compare-and-swap."""
    def check(target: Path) -> tuple[bool, str]:
        if fingerprint(target, remaining=remaining) != expected:
            return False, EVIDENCE_CHANGED
        return verify(target)
    return check


def event_id(installation_id: str, payload: dict) -> str:
    """Derive the deterministic event ID from the complete canonical payload.

    Keying on the whole payload (not just kind, path and fingerprint) means a
    later pass that sees the same tree with different reason or references
    appends a new event instead of colliding with the earlier one, which would
    otherwise refuse that tree permanently as ``journal-conflict``.
    """
    return str(uuid5(UUID(installation_id), encode(payload)))


def record(store: LifecycleRegistry, kind: str, verdict: dict, digest: str,
           archive: dict | None = None) -> str | None:
    """Journal one reclaim event; return None on success or the failure reason.

    The payload carries no clock value: an identical replay must match the stored
    payload exactly, which is what makes a repeated pass idempotent. A stage-2
    event also carries the archive id (``archive``: path and manifest sha256).
    """
    payload = {"type": kind, "schema": 1, "path": verdict["path"], "fingerprint": digest,
               "reason": verdict.get("reason"), "repository": verdict.get("repository"),
               "references": verdict.get("references", [])}
    if archive is not None:
        payload["archive"] = archive
    try:
        with store.connection(write=True) as connection:
            installation = connection.execute(
                "SELECT installation_id FROM metadata").fetchone()[0]
            append_event(connection, event_id(installation, payload), payload)
    except StoreConflict:
        return "journal-conflict"
    except (StoreCapacity, ValueError, TypeError, LookupError, RuntimeError, OSError,
            sqlite3.Error):
        # An unwritable journal refuses removal; it must not end the pass.
        return "journal-unavailable"
    return None
