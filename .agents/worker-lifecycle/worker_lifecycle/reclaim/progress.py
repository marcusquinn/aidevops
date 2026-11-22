# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Pass-to-pass progress for the reclaim sweep: scan cursor and unreadable backoff.

A pass stopped by its budget or limit records the last worktree it reached, and
the next pass resumes after it, so a slow head of the listing cannot starve the
tail forever (GH#38376). A worktree whose own local state stays unreadable on
consecutive passes is deferred through a path-keyed ``CleanupQuarantine``,
so it stops spending every pass's budget. Both are advisory: unreadable progress
state degrades to scanning from the start with nothing deferred, and neither
ever authorizes a removal.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile

from ..cleanup_quarantine import CleanupQuarantine
from ..filesystem import validate_private_path

CURSOR_NAME = "reclaim-cursor"
QUARANTINE_NAME = "reclaim-quarantine"
_CURSOR_MAX_BYTES = 4096
# Consecutive unreadable refusals before a worktree is deferred.
QUARANTINE_THRESHOLD = 2
# Refusals that describe this worktree's own unreadable local state. Pass-wide
# failures (``owner-observation-unavailable``) and GitHub answers are excluded:
# deferring every tree for an outage, or a tree for an unresolved lookup, would
# hide work the next healthy pass can judge.
UNREADABLE = frozenset({
    "repository-unknown", "status-unreadable", "unpushed-state-unreadable",
    "owner-registry-unreadable", "owner-unobservable", "fingerprint-unavailable",
})
# Stage-2 failures of this tree's own archive (GH#38394). A timed-out archive
# repeats for the same tree and can spend the whole pass budget, so it backs off.
# Capacity is host-wide and fails fast, so it stays out: one capacity failure
# must not defer every tree.
ARCHIVE_FAILURES = frozenset({"archive-failed", "archive-verify-failed", "archive-timeout"})


def unreadable(verdict: dict) -> bool:
    """Report whether a judged worktree refused, or failed, on its own unreadable state."""
    return (verdict.get("reason") in UNREADABLE
            or verdict.get("removal") in UNREADABLE | ARCHIVE_FAILURES)


def open_quarantine(state_dir: Path) -> CleanupQuarantine | None:
    """Open the reclaim quarantine, or None when the state directory is absent."""
    if not state_dir.is_dir():
        return None
    return CleanupQuarantine(state_dir, QUARANTINE_NAME)


def read_cursor(state_dir: Path) -> str:
    """Return the worktree name the last stopped pass reached, or "" to start over."""
    path = state_dir / CURSOR_NAME
    try:
        validate_private_path(path)
        if path.stat().st_size > _CURSOR_MAX_BYTES:
            return ""
        value = json.loads(path.read_text(encoding="utf-8")).get("after", "")
    except (FileNotFoundError, ValueError, OSError, AttributeError):
        return ""
    # A cursor is one directory name; anything else is ignored, never followed.
    if not isinstance(value, str) or not value or "/" in value or value in (".", ".."):
        return ""
    return value


def write_cursor(state_dir: Path, after: str) -> bool:
    """Persist the resume point atomically; "" clears it. Returns False on failure."""
    path = state_dir / CURSOR_NAME
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=state_dir,
                                         prefix=f".{CURSOR_NAME}-", delete=False) as stream:
            temporary = Path(stream.name)
            json.dump({"after": after}, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    except OSError:
        return False
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return True


def ordered(paths: list[Path], after: str) -> list[Path]:
    """Sort candidates, rotated to start just after ``after`` and wrap around."""
    names = sorted(paths, key=lambda path: path.name)
    if not after:
        return names
    return ([path for path in names if path.name > after]
            + [path for path in names if path.name <= after])


def listing(base_dir: Path) -> list[Path]:
    """Every directory directly under the base, the pass's candidate universe."""
    return [path for path in base_dir.iterdir() if path.is_dir()]


def deferred(quarantine: CleanupQuarantine | None, path: Path) -> bool:
    """Report whether this tree is inside its unreadable-state backoff window."""
    return quarantine is not None and quarantine.deferred(str(path))


def remember(quarantine: CleanupQuarantine | None, path: Path, verdict: dict) -> None:
    """Feed one applied judgement to the backoff.

    Any readable outcome clears the entry; only consecutive unreadable refusals
    of this same tree defer it.
    """
    if quarantine is not None:
        quarantine.record(str(path), verdict, retry_later=unreadable(verdict),
                          threshold=QUARANTINE_THRESHOLD)


def save_progress(state_dir: Path, universe: list[Path],
                  quarantine: CleanupQuarantine | None, receipt: dict) -> None:
    """Persist the cursor and backoff of an applied pass; dry runs never call this.

    A failed write is reported, never fatal: the next pass then rescans from the
    previous cursor, which costs time but skips nothing.
    """
    if not state_dir.is_dir():
        receipt["cursor_unavailable"] = True
        return
    if receipt["resume_after"] != receipt["cursor_start"] and not write_cursor(
            state_dir, receipt["resume_after"]):
        receipt["cursor_unavailable"] = True
    if quarantine is not None:
        quarantine.retain({str(path) for path in universe if path.exists()})
        quarantine.save(receipt)
