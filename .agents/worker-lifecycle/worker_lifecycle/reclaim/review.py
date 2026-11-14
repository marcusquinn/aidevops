# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""The one exception to finished work: an idle review worktree of an open PR.

Review worktrees (``<repo>-pr<N>-review-<slug>``) are disposable checkouts of
pull request N's head, and that PR stays open long after the review ends. For
this shape PR N alone decides: the head branch's references later in the name
describe the same work. An open PR qualifies only once Git has been idle there
for ``IDLE_SECONDS``, re-checked at removal, and every other reclaim check
still applies.
"""

from __future__ import annotations

from pathlib import Path
import re
import time

from .host import metadata_directory, nothing_to_lose

IDLE_SECONDS = 2 * 60 * 60


def own_pull_request(name: str, slug: str) -> int | None:
    """The PR a review worktree checks out, or None for any other shape.

    Anchored on the origin's repository name, so a worker tree that merely
    mentions a review later in its name is not a review worktree.
    """
    repo = slug.rsplit("/", 1)[-1].lower()
    match = re.match(rf"{re.escape(repo)}-pr(\d{{1,8}})-review-", name.lower())
    return int(match.group(1)) if match else None


def idle_seconds(path: Path) -> float | None:
    """Seconds since Git last moved HEAD or the index, or None when unreadable.

    Both live in the worktree's own metadata directory, so a checkout, commit,
    rebase or staging operation in this tree refreshes them.
    """
    metadata = metadata_directory(path)
    entries = [metadata / "HEAD", metadata / "index"] if metadata is not None else []
    times = []
    for entry in entries:
        try:
            times.append(entry.stat().st_mtime)
        except OSError:
            continue
    return time.time() - max(times) if times else None


def still_idle(path: Path) -> bool:
    """Unreadable idleness refuses: only a measured quiet period qualifies."""
    idle = idle_seconds(path)
    return idle is not None and idle >= IDLE_SECONDS


def verify_idle_review(path: Path, *, timeout: int = 60) -> tuple[bool, str]:
    """Removal-time re-check for ``review-idle``: still quiet, still nothing to lose."""
    if not still_idle(path):
        return False, "review-active"
    return nothing_to_lose(path, timeout=timeout)
