# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""The one exception to finished work: an idle review worktree of an open PR.

Review worktrees (``<repo>-pr<N>-review-<slug>``) are disposable reads of an open
pull request, and that PR stays open long after the review ends. Only this shape
may be removed while its pull request is open, only once Git has been idle there
for ``IDLE_SECONDS``, and still only after every other reclaim check passes.
"""

from __future__ import annotations

from pathlib import Path
import re
import time

from .host import metadata_directory

TREE = re.compile(r"(?<![a-z0-9])pr\d{1,8}-review-")
IDLE_SECONDS = 2 * 60 * 60


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


def idle_review(path: Path, unfinished: str) -> bool:
    """Accept an open pull request only for an idle review worktree.

    Unknown PR state still refuses: only a confirmed open review qualifies.
    """
    if TREE.search(path.name.lower()) is None or not unfinished.endswith("-open"):
        return False
    idle = idle_seconds(path)
    return idle is not None and idle >= IDLE_SECONDS
