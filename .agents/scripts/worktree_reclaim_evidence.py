#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Evidence for reclaiming a finished worktree; every unreadable signal refuses.

This supplies none of the six proofs ``worker_lifecycle.cleanup_policy`` requires
and reports no cleanup authorization. It answers one narrower question: has this
worktree's work finished, and would removing it lose anything? Because removal is
archive-free, each check here fails closed.
"""

from __future__ import annotations

import json
from pathlib import Path
import re

from worktree_reclaim_host import git, occupied, run

REFERENCE = re.compile(r"(?:^|[^a-z])(gh|pr)(\d{2,8})(?:[^0-9]|$)")
REMOTE_SLUG = re.compile(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$")


def references(name: str) -> list[tuple[str, int]]:
    """Extract every issue and pull request number encoded in a worktree name."""
    found: list[tuple[str, int]] = []
    for kind, number in REFERENCE.findall(name.lower()):
        entry = (kind, int(number))
        if entry not in found:
            found.append(entry)
    return found


def repository(path: Path) -> str | None:
    status, url = git(path, "remote", "get-url", "origin")
    match = REMOTE_SLUG.search(url.strip()) if status == 0 and url else None
    return match.group(1) if match else None


def reference_finished(kind: str, number: int, slug: str, cache: dict) -> tuple[bool, str]:
    """Report whether one reference is finished: an issue closed, or a merge.

    A pull request closed without merging is not finished work, so only MERGED
    authorizes removal.
    """
    key = (kind, number, slug)
    if key not in cache:
        noun, done = ("issue", "CLOSED") if kind == "gh" else ("pr", "MERGED")
        status, output = run(
            ["gh", noun, "view", str(number), "--repo", slug, "--json", "state"],
        )
        state = json.loads(output).get("state") if status == 0 and output else None
        cache[key] = (state == done, f"{noun}-{number}-{str(state).lower()}")
    return cache[key]


def nothing_to_lose(path: Path) -> tuple[bool, str]:
    """Confirm no uncommitted, untracked, or unpushed work exists in the worktree."""
    status, dirty = git(path, "status", "--porcelain")
    if status != 0:
        return False, "status-unreadable"
    if dirty:
        return False, "uncommitted-changes"
    status, unpushed = git(path, "rev-list", "--count", "HEAD", "--not", "--remotes")
    if status != 0 or not unpushed.isdigit():
        return False, "unpushed-state-unreadable"
    return (unpushed == "0"), ("nothing-to-lose" if unpushed == "0"
                               else f"unpushed-commits-{unpushed}")


def _preconditions(path: Path, census: set[Path] | None) -> str | None:
    """Name the first missing precondition for judging this path at all."""
    failures = ((census is None, "process-inventory-unavailable"),
                (not (path / ".git").exists(), "not-a-worktree"))
    return next((reason for failed, reason in failures if failed), None)


def _identity(path: Path, found: list[tuple[str, int]], verdict: dict) -> str | None:
    """Record the repository and references a decision needs, naming what is absent."""
    slug = repository(path)
    if slug is None:
        return "repository-unknown"
    verdict["repository"] = slug
    verdict["references"] = [f"{kind}{number}" for kind, number in found]
    return None if found else "reference-unknown"


def _unfinished(slug: str, found: list[tuple[str, int]], cache: dict) -> str | None:
    """Name the first reference whose work has not finished."""
    for kind, number in found:
        finished, detail = reference_finished(kind, number, slug, cache)
        if not finished:
            return detail
    return None


def _unsafe_to_remove(path: Path, census: set[Path]) -> str | None:
    """Name what removal would disturb or discard, or nothing when it is safe."""
    if occupied(path, census):
        return "writers-present"
    clean, detail = nothing_to_lose(path)
    return None if clean else detail


def evidence(path: Path, census: set[Path] | None, cache: dict) -> dict:
    """Decide one worktree, reporting the first missing proof as the reason."""
    verdict: dict = {"path": str(path), "authorized": False, "reason": "unevaluated"}
    found = references(path.name)
    reason = _preconditions(path, census)
    if reason is None:
        reason = _identity(path, found, verdict)
    if reason is None:
        reason = _unfinished(verdict["repository"], found, cache)
    if reason is None and census is not None:
        reason = _unsafe_to_remove(path, census)
    verdict["authorized"] = reason is None
    verdict["reason"] = reason or "work-finished"
    return verdict
