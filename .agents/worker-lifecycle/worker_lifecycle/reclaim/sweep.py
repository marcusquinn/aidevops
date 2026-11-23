# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Remove worktrees whose work is provably finished; refuse on any missing evidence.

This is an always-on interim pass of the pulse cleanup stage, not the cleanup
evidence collector that
``worker_lifecycle.cleanup_policy.decide_cleanup`` expects. It claims none of that
policy's six proofs and reports no ``cleanup_authorized``. Stage-1 removal is
archive-free by explicit operator decision, so the checks in
``worker_lifecycle.reclaim.evidence`` are the only protection and each fails closed.

Each candidate gets one decision (``reclaim.decision.classify``): ``remove``,
``archive`` (finished work with local state to preserve) or ``refuse``. Stage 1
removes ``remove`` trees as it judges them; ``archive`` trees are queued for
stage 2 (``reclaim.archive``, GH#38394), which runs after every candidate was
judged: archive with commits bundled, verify, journal, then remove. Dry runs
write nothing; applied removals are journaled as ``reclaim-authorized`` (or
``reclaim-archived``) then ``reclaim-removed`` (GH#38348).
Applied passes also persist a scan cursor and defer trees whose own state stays
unreadable (``reclaim.progress``, GH#38376); dry runs honour both but update neither.
"""

from __future__ import annotations

import argparse
from collections.abc import Iterator
from dataclasses import dataclass, field, replace
import json
import os
from pathlib import Path
import sys
import time

from .decision import (
    ARCHIVE, AUTHORIZED, REFUSE, REMOVE, REMOVED, cas_verify, classify, fingerprint, record,
)
from .archive import stage_two
from .evidence import evidence, prefetch, references, repository
from .host import common_directory, free_bytes, remove, run
from ..cleanup_quarantine import CleanupQuarantine
from ..storage import LifecycleRegistry
from .owners import RESIDUAL_RISK, OwnerCheck, default_state_dir, open_owners
from .progress import (
    deferred, listing, open_quarantine, ordered, read_cursor, remember, save_progress,
)
from .review import idle_verifier

SCHEMA = "aidevops.worktree-reclaim-finished/v1"
# Largest fraction of the remaining pass budget reference prefetch may spend.
PREFETCH_SHARE = 0.5
# Re-exported for callers and tests that treat this script as the entry point.
__all__ = ["SCHEMA", "evidence", "main", "references"]


@dataclass(frozen=True)
class Pass:
    """One pass's host observation and settings, read once and shared per path."""

    owner: OwnerCheck | None
    apply_removal: bool
    deadline: float
    limit: int = 0
    finished: dict = field(default_factory=dict)
    quarantine: CleanupQuarantine | None = None
    # ``archive`` trees judged in stage 1, in order, for stage 2.
    queued: list = field(default_factory=list)

    def remaining(self) -> int:
        """Report whole seconds left, so no child outlives the pass budget."""
        return max(int(self.deadline - time.monotonic()), 0)


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    default_base = Path(os.environ.get("AIDEVOPS_WORKTREE_BASE_DIR",
                                       Path.home() / "Git" / "_worktrees"))
    parser.add_argument("--base-dir", type=Path, default=default_base)
    parser.add_argument("--state-dir", type=Path, default=None,
                        help="lifecycle registry directory; the pulse passes its own")
    parser.add_argument("--apply", action="store_true",
                        help="remove authorized worktrees; default reports only")
    parser.add_argument("--budget-seconds", type=int, default=300)
    parser.add_argument("--limit", type=int, default=0, help="0 means no limit")
    arguments = parser.parse_args(argv)
    # The registry records absolute generation paths, so candidates must match.
    arguments.base_dir = arguments.base_dir.absolute()
    arguments.state_dir = (arguments.state_dir or default_state_dir()).absolute()
    return arguments


def new_receipt(base_dir: Path, *, dry_run: bool) -> dict:
    return {"schema": SCHEMA, "base_dir": str(base_dir), "dry_run": dry_run,
            "scanned": 0, "authorized": 0, "archive_queued": 0, "archived": 0, "removed": 0,
            "failed": 0, "refused": 0, "quarantine_deferred": 0,
            "cursor_start": "", "resume_after": "",
            "reclaimed_bytes": 0, "budget_exhausted": False,
            "residual_risk": RESIDUAL_RISK, "results": []}


def judge(path: Path, current: Pass, receipt: dict) -> dict:
    """Collect evidence and the three-way decision for one worktree; never writes.

    The fingerprint is taken before evidence is collected, so a change at any
    point after it (during judgement included) fails the removal-time CAS.
    """
    digest = fingerprint(path, remaining=current.remaining)
    verdict = evidence(path, current.owner, current.finished,
                       timeout=min(current.remaining(), 60))
    verdict["decision"], _ = classify(verdict)
    receipt["results"].append(verdict)
    if verdict["decision"] == REFUSE:
        receipt["refused"] += 1
    elif verdict["decision"] == ARCHIVE:
        # Archived and removed by stage 2 once every candidate was judged.
        receipt["archive_queued"] += 1
    else:
        receipt["authorized"] += 1
    if verdict["decision"] != REFUSE:
        verdict["fingerprint"] = digest
    return verdict


def reclaim_one(path: Path, current: Pass, receipt: dict) -> Path | None:
    """Judge one worktree and, when removable and applying, remove it.

    Removal is journaled before and after (``decision.record``) and refused when
    the evidence fingerprint changed since judgement. An applied pass also feeds
    the outcome to the unreadable backoff (``reclaim.progress``). Returns the
    repository needing a worktree prune, or None.
    """
    verdict = judge(path, current, receipt)
    if verdict["decision"] == ARCHIVE:
        # Stage 2 acts on it and feeds its own outcome to the backoff.
        current.queued.append((path, verdict))
        return None
    common = _act(path, verdict, current, receipt)
    if current.apply_removal:
        remember(current.quarantine, path, verdict)
    return common


def _act(path: Path, verdict: dict, current: Pass, receipt: dict) -> Path | None:
    """Remove one judged worktree when its decision and the pass allow it."""
    # A remove decision implies owners were observed; the check narrows the type.
    if (verdict["decision"] != REMOVE or not current.apply_removal
            or current.owner is None):
        return None
    if current.remaining() == 0:
        # Never start destructive work the budget can no longer cover.
        receipt["budget_exhausted"] = True
        verdict["removal"] = "budget-exhausted"
        return None
    store: LifecycleRegistry | None = getattr(current.owner, "store", None)
    digest = verdict["fingerprint"]
    blocked = ("fingerprint-unavailable" if digest is None
               else "journal-unavailable" if store is None
               else record(store, AUTHORIZED, verdict, digest))
    if blocked is not None or store is None:
        verdict["removal"] = blocked or "journal-unavailable"
        receipt["failed"] += 1
        return None
    common = common_directory(path)
    # An idle tree was authorized for being quiet, so removal re-checks that too.
    verify = idle_verifier(verdict["reason"])
    removed, detail = remove(path, cas_verify(digest, verify, current.remaining), current.owner)
    verdict["removal"] = detail
    if not removed:
        receipt["failed"] += 1
        return None
    receipt["removed"] += 1
    # The tree is gone either way; an unrecorded outcome is reported, not hidden.
    unrecorded = record(store, REMOVED, verdict, digest)
    if unrecorded is not None:
        verdict["journal"] = unrecorded
    return common


def candidates(paths: list[Path], current: Pass, receipt: dict) -> Iterator[Path]:
    """Yield worktrees in cursor order until the budget or limit stops the pass.

    Deferred trees are skipped before the limit applies, so they cannot occupy
    it. ``resume_after`` names where the next pass starts: the last tree reached
    when the pass stopped early, or "" once the whole listing was covered.
    """
    receipt["resume_after"] = receipt.get("cursor_start", "")
    for path in paths:
        if current.remaining() == 0:
            receipt["budget_exhausted"] = True
            return
        if current.limit and receipt["scanned"] >= current.limit:
            return
        if deferred(current.quarantine, path):
            receipt["quarantine_deferred"] += 1
            continue
        receipt["scanned"] += 1
        receipt["resume_after"] = path.name
        yield path
    receipt["resume_after"] = ""


def reclaimed_bytes(before: int | None, after: int | None, removed: int) -> int:
    """Report the pass-level free-space gain; unreadable or no removal means zero."""
    if before is None or after is None or removed == 0:
        return 0
    return max(after - before, 0)


def prefetch_references(paths: list[Path], current: Pass) -> None:
    """Resolve the references this pass will judge, in batches, before judging any.

    The order, deferral and limit the candidate generator applies are applied
    here too, so a limited run does not spend its budget resolving trees it will
    never reach. A failed batch leaves the cache untouched, so judgement falls
    back to per-reference queries.

    Prefetch gets at most ``PREFETCH_SHARE`` of the remaining budget: a stalled
    batch must not leave judgement no time to yield a tree, or the cursor would
    never advance and the tail would starve again (GH#38376).
    """
    share = replace(current, deadline=time.monotonic() + current.remaining() * PREFETCH_SHARE)
    wanted: dict[str, list[tuple[str, int]]] = {}
    examined = 0
    for path in paths:
        if share.remaining() == 0 or (current.limit and examined >= current.limit):
            break
        if deferred(current.quarantine, path):
            continue
        examined += 1
        found = references(path.name)
        if path.is_symlink() or not found:
            continue
        slug = repository(path, timeout=min(share.remaining(), 60))
        if slug:
            wanted.setdefault(slug, []).extend(found)
    prefetch(wanted, current.finished, remaining=share.remaining)


def main() -> int:
    arguments = parse_arguments()
    receipt = new_receipt(arguments.base_dir, dry_run=not arguments.apply)
    if not arguments.base_dir.is_dir():
        receipt["reason"] = "base-dir-absent"
        print(json.dumps(receipt))
        return 0
    owner = open_owners(arguments.state_dir)
    current = Pass(owner=owner, apply_removal=arguments.apply,
                   deadline=time.monotonic() + max(arguments.budget_seconds, 1),
                   limit=arguments.limit, quarantine=open_quarantine(arguments.state_dir))
    receipt["owner_observation"] = "registry" if owner else "unavailable"
    receipt["cursor_start"] = read_cursor(arguments.state_dir)
    universe = listing(arguments.base_dir)
    paths = ordered(universe, receipt["cursor_start"])
    repositories: set[Path] = set()
    free_before = free_bytes(arguments.base_dir)
    prefetch_references(paths, current)
    for path in candidates(paths, current, receipt):
        common = reclaim_one(path, current, receipt)
        if common is not None:
            repositories.add(common)
    repositories |= stage_two(current.queued, current, receipt)
    for common in repositories:
        run(["git", "--git-dir", str(common), "worktree", "prune"])
    receipt["reclaimed_bytes"] = reclaimed_bytes(
        free_before, free_bytes(arguments.base_dir), receipt["removed"])
    if arguments.apply:
        save_progress(arguments.state_dir, universe, current.quarantine, receipt)
    print(json.dumps(receipt))
    return 0


if __name__ == "__main__":
    sys.exit(main())
