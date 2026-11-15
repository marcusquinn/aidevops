# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""The idle exceptions to finished work: trees quiet long enough to be disposable.

Each shape in ``SHAPES`` names a worktree whose reference is still open (or absent)
yet whose Git state has been idle for the shape's threshold, re-checked at removal;
every other reclaim check still applies. Review worktrees
(``<repo>-pr<N>-review-<slug>``) are judged by PR N alone, a worker tree
(``<repo>-feature-auto-<timestamp>-gh<N>``) by its open issue, and a tree with no
reference by idleness alone. A redispatched worker creates a fresh tree, so an
idle one with nothing to lose costs nothing to remove. Unlisted shapes refuse.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
import re
import time

from .host import metadata_directory, nothing_to_lose

IDLE_SECONDS = 2 * 60 * 60
WORKER_IDLE_SECONDS = 6 * 60 * 60
UNREFERENCED_IDLE_SECONDS = 72 * 60 * 60


@dataclass(frozen=True)
class Shape:
    """One idle-exception shape; ``{repo}`` is the origin's repository name."""

    pattern: str
    kind: str | None  # reference kind judged ("pr", "gh"); None when unreferenced
    seconds: int
    reason: str
    active: str


SHAPES = (
    Shape(r"{repo}-pr(\d{{1,8}})-review-", "pr", IDLE_SECONDS,
          "review-idle", "review-active"),
    Shape(r"{repo}-feature-auto-[0-9-]+-gh(\d{{1,8}})$", "gh", WORKER_IDLE_SECONDS,
          "worker-idle", "worker-active"),
    Shape(r"{repo}-feature-auto-[0-9-]+-\d+$", None, UNREFERENCED_IDLE_SECONDS,
          "unreferenced-idle", "unreferenced-active"),
)
BY_REASON = {shape.reason: shape for shape in SHAPES}


def idle_shape(name: str, slug: str) -> tuple[Shape, int | None] | None:
    """The idle shape a worktree name has and the number it judges, or None.

    Anchored on the origin's repository name, so a tree that merely mentions a
    review or worker shape later in its name is not one.
    """
    repo = re.escape(slug.rsplit("/", 1)[-1].lower())
    for shape in SHAPES:
        match = re.match(shape.pattern.format(repo=repo), name.lower())
        if match:
            return shape, int(match.group(1)) if shape.kind else None
    return None


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


def still_idle(path: Path, seconds: int = IDLE_SECONDS) -> bool:
    """Unreadable idleness refuses: only a measured quiet period qualifies."""
    idle = idle_seconds(path)
    return idle is not None and idle >= seconds


def unfinished(path: Path, found: list[tuple[str, int]], slug: str,
               reference_finished: Callable[[str, int], tuple[bool, str]],
               ) -> tuple[str | None, str]:
    """Name the first unfinished reference, or how the work counts as finished.

    An idle shape is judged by its own reference alone; one confirmed open, or
    absent for the unreferenced shape, qualifies once idle for its threshold.
    Every later evidence check still applies to it.
    """
    match = idle_shape(path.name, slug)
    shape, own = match if match else (None, None)
    if shape is not None and shape.kind is None:
        quiet = not found and still_idle(path, shape.seconds)
        return (None, shape.reason) if quiet else ("reference-unknown", "")
    judged = ([(shape.kind, own)]
              if shape is not None and shape.kind is not None and own is not None
              else found)
    for kind, number in judged:
        finished, detail = reference_finished(kind, number)
        if not finished:
            return _open_reference(path, shape, (kind, number), detail)
    return None, "work-finished"


def _open_reference(path: Path, shape: Shape | None, ref: tuple[str, int],
                    detail: str) -> tuple[str | None, str]:
    """An open reference blocks, unless its idle shape has been quiet long enough."""
    noun = "issue" if ref[0] == "gh" else "pr"
    if shape is not None and detail == f"{noun}-{ref[1]}-open" \
            and still_idle(path, shape.seconds):
        return None, shape.reason
    return detail, ""


def idle_verifier(reason: str) -> Callable[[Path], tuple[bool, str]]:
    """Removal-time re-check for an idle reason: still quiet, still nothing to lose.

    Any other reason gets the plain nothing-to-lose check.
    """
    shape = BY_REASON.get(reason)

    def verify(path: Path, *, timeout: int = 60) -> tuple[bool, str]:
        if shape is not None and not still_idle(path, shape.seconds):
            return False, shape.active
        return nothing_to_lose(path, timeout=timeout)

    return verify
