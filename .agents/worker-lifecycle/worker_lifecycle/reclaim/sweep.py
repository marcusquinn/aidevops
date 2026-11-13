# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Remove worktrees whose work is provably finished; refuse on any missing evidence.

This is an always-on interim pass of the pulse cleanup stage, not the cleanup
evidence collector that
``worker_lifecycle.cleanup_policy.decide_cleanup`` expects. It claims none of that
policy's six proofs and reports no ``cleanup_authorized``. Removal is archive-free
by explicit operator decision, so the checks in ``worker_lifecycle.reclaim.evidence`` are
the only protection and each fails closed.
"""

from __future__ import annotations

import argparse
from collections.abc import Iterator
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import sys
import time

from .evidence import (
    evidence, nothing_to_lose, prefetch, references, repository)
from .host import Census, common_directory, free_bytes, process_census, remove, run

SCHEMA = "aidevops.worktree-reclaim-finished/v1"
# Re-exported for callers and tests that treat this script as the entry point.
__all__ = ["SCHEMA", "evidence", "main", "references"]


@dataclass(frozen=True)
class Pass:
    """One pass's host observation and settings, read once and shared per path."""

    census: Census | None
    apply_removal: bool
    deadline: float
    limit: int = 0
    finished: dict = field(default_factory=dict)

    def remaining(self) -> int:
        """Report whole seconds left, so no child outlives the pass budget."""
        return max(int(self.deadline - time.monotonic()), 0)


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    default_base = Path(os.environ.get("AIDEVOPS_WORKTREE_BASE_DIR",
                                       Path.home() / "Git" / "_worktrees"))
    parser.add_argument("--base-dir", type=Path, default=default_base)
    parser.add_argument("--apply", action="store_true",
                        help="remove authorized worktrees; default reports only")
    parser.add_argument("--budget-seconds", type=int, default=300)
    parser.add_argument("--limit", type=int, default=0, help="0 means no limit")
    arguments = parser.parse_args(argv)
    # The census reports absolute paths, so candidate identity must be absolute too.
    arguments.base_dir = arguments.base_dir.absolute()
    return arguments


def new_receipt(base_dir: Path, *, dry_run: bool) -> dict:
    return {"schema": SCHEMA, "base_dir": str(base_dir), "dry_run": dry_run,
            "scanned": 0, "authorized": 0, "removed": 0, "failed": 0, "refused": 0,
            "reclaimed_bytes": 0, "budget_exhausted": False,
            "unplaceable_processes": 0, "results": []}


def reclaim_one(path: Path, current: Pass, receipt: dict) -> Path | None:
    """Judge one worktree and, when authorized and applying, remove it.

    Returns the repository needing a worktree prune, or None.
    """
    verdict = evidence(path, current.census, current.finished,
                       timeout=min(current.remaining(), 60))
    receipt["results"].append(verdict)
    if not verdict["authorized"]:
        receipt["refused"] += 1
        return None
    receipt["authorized"] += 1
    if not current.apply_removal:
        return None
    if current.remaining() == 0:
        # Never start destructive work the budget can no longer cover.
        receipt["budget_exhausted"] = True
        verdict["removal"] = "budget-exhausted"
        return None
    common = common_directory(path)
    removed, detail = remove(path, nothing_to_lose)
    verdict["removal"] = detail
    if not removed:
        receipt["failed"] += 1
        return None
    receipt["removed"] += 1
    return common


def candidates(base_dir: Path, current: Pass, receipt: dict) -> Iterator[Path]:
    """Yield each worktree directory until the budget or limit stops the pass."""
    for path in sorted(base_dir.iterdir()):
        if not path.is_dir():
            continue
        if current.remaining() == 0:
            receipt["budget_exhausted"] = True
            return
        if current.limit and receipt["scanned"] >= current.limit:
            return
        receipt["scanned"] += 1
        yield path


def reclaimed_bytes(before: int | None, after: int | None, removed: int) -> int:
    """Report the pass-level free-space gain; unreadable or no removal means zero."""
    if before is None or after is None or removed == 0:
        return 0
    return max(after - before, 0)


def prefetch_references(base_dir: Path, current: Pass) -> None:
    """Resolve the references this pass will judge, in batches, before judging any.

    The limit the candidate generator applies is applied here too, so a limited run
    does not spend its budget resolving trees it will never reach. A failed batch
    leaves the cache untouched, so judgement falls back to per-reference queries.
    """
    wanted: dict[str, list[tuple[str, int]]] = {}
    examined = 0
    for path in sorted(base_dir.iterdir()):
        if not path.is_dir():
            continue
        if current.remaining() == 0 or (current.limit and examined >= current.limit):
            break
        examined += 1
        found = references(path.name)
        if path.is_symlink() or not found:
            continue
        slug = repository(path, timeout=min(current.remaining(), 60))
        if slug:
            wanted.setdefault(slug, []).extend(found)
    prefetch(wanted, current.finished, remaining=current.remaining)


def main() -> int:
    arguments = parse_arguments()
    receipt = new_receipt(arguments.base_dir, dry_run=not arguments.apply)
    if not arguments.base_dir.is_dir():
        receipt["reason"] = "base-dir-absent"
        print(json.dumps(receipt))
        return 0
    census = process_census()
    current = Pass(census=census, apply_removal=arguments.apply,
                   deadline=time.monotonic() + max(arguments.budget_seconds, 1),
                   limit=arguments.limit)
    receipt["unplaceable_processes"] = census.unplaceable if census else 0
    repositories: set[Path] = set()
    free_before = free_bytes(arguments.base_dir)
    prefetch_references(arguments.base_dir, current)
    for path in candidates(arguments.base_dir, current, receipt):
        common = reclaim_one(path, current, receipt)
        if common is not None:
            repositories.add(common)
    for common in repositories:
        run(["git", "--git-dir", str(common), "worktree", "prune"])
    receipt["reclaimed_bytes"] = reclaimed_bytes(
        free_before, free_bytes(arguments.base_dir), receipt["removed"])
    print(json.dumps(receipt))
    return 0


if __name__ == "__main__":
    sys.exit(main())
