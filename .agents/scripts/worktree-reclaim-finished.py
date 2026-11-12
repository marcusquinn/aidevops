#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Remove worktrees whose work is provably finished; refuse on any missing evidence.

This is an explicitly opt-in interim pass, not the cleanup evidence collector that
``worker_lifecycle.cleanup_policy.decide_cleanup`` expects. It claims none of that
policy's six proofs and reports no ``cleanup_authorized``. Removal is archive-free
by explicit operator decision, so the checks in ``worktree_reclaim_evidence`` are
the only protection and each fails closed.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import sys
import time

from worktree_reclaim_evidence import evidence, references
from worktree_reclaim_host import common_directory, directory_size, remove, run, working_directories

SCHEMA = "aidevops.worktree-reclaim-finished/v1"
# Re-exported for callers and tests that treat this script as the entry point.
__all__ = ["SCHEMA", "evidence", "main", "references", "remove"]


@dataclass(frozen=True)
class Pass:
    """One pass's host observations and settings, read once and shared per path."""

    census: set[Path] | None
    apply_removal: bool
    deadline: float
    limit: int = 0
    finished: dict = field(default_factory=dict)


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    default_base = Path(os.environ.get("AIDEVOPS_WORKTREE_BASE_DIR",
                                       Path.home() / "Git" / "_worktrees"))
    parser.add_argument("--base-dir", type=Path, default=default_base)
    parser.add_argument("--apply", action="store_true",
                        help="remove authorized worktrees; default reports only")
    parser.add_argument("--budget-seconds", type=int, default=300)
    parser.add_argument("--limit", type=int, default=0, help="0 means no limit")
    return parser.parse_args(argv)


def new_receipt(base_dir: Path, *, dry_run: bool) -> dict:
    return {"schema": SCHEMA, "base_dir": str(base_dir), "dry_run": dry_run,
            "scanned": 0, "authorized": 0, "removed": 0, "failed": 0, "refused": 0,
            "reclaimed_bytes": 0, "budget_exhausted": False, "results": []}


def reclaim_one(path: Path, current: Pass, receipt: dict) -> Path | None:
    """Judge one worktree and, when authorized and applying, remove it.

    Returns the repository needing a worktree prune, or None.
    """
    verdict = evidence(path, current.census, current.finished)
    receipt["results"].append(verdict)
    if not verdict["authorized"]:
        receipt["refused"] += 1
        return None
    receipt["authorized"] += 1
    verdict["bytes"] = directory_size(path)
    if not current.apply_removal:
        return None
    common = common_directory(path)
    removed, detail = remove(path)
    verdict["removal"] = detail
    if not removed:
        receipt["failed"] += 1
        return None
    receipt["removed"] += 1
    receipt["reclaimed_bytes"] += verdict["bytes"]
    return common


def candidates(base_dir: Path, current: Pass, receipt: dict):
    """Yield each worktree directory until the budget or limit stops the pass."""
    for path in sorted(base_dir.iterdir()):
        if not path.is_dir():
            continue
        if time.monotonic() >= current.deadline:
            receipt["budget_exhausted"] = True
            return
        if current.limit and receipt["scanned"] >= current.limit:
            return
        receipt["scanned"] += 1
        yield path


def main() -> int:
    arguments = parse_arguments()
    receipt = new_receipt(arguments.base_dir, dry_run=not arguments.apply)
    if not arguments.base_dir.is_dir():
        receipt["reason"] = "base-dir-absent"
        print(json.dumps(receipt))
        return 0
    current = Pass(census=working_directories(), apply_removal=arguments.apply,
                   deadline=time.monotonic() + max(arguments.budget_seconds, 1),
                   limit=arguments.limit)
    repositories: set[Path] = set()
    for path in candidates(arguments.base_dir, current, receipt):
        common = reclaim_one(path, current, receipt)
        if common is not None:
            repositories.add(common)
    for common in repositories:
        run(["git", "--git-dir", str(common), "worktree", "prune"])
    print(json.dumps(receipt))
    return 0


if __name__ == "__main__":
    sys.exit(main())
