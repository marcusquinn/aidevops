# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Evidence for reclaiming a finished worktree; every unreadable signal refuses.

This supplies none of the six proofs ``worker_lifecycle.cleanup_policy`` requires
and reports no cleanup authorization. It answers one narrower question: has this
worktree's work finished, and would removing it lose anything? Because removal is
archive-free, each check here fails closed.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
import json
from pathlib import Path
import re

from .host import Census, git, locked, metadata_directory, run

# Non-consuming boundaries: adjacent references such as repo-gh42-pr9001 must both
# be found, because one closed reference must never authorize removal while the
# other is still open.
REFERENCE = re.compile(r"(?<![a-z0-9])(gh|pr)(\d{1,8})(?![0-9])")
# Only GitHub origins are supported: a hostless slug would query an unrelated
# repository of the same name on GitHub.
REMOTE_SLUG = re.compile(
    r"^(?:git@github\.com:|ssh://git@github\.com/|git://github\.com/"
    r"|https?://(?:[^@/]+@)?github\.com/)([^/]+/[^/]+?)(?:\.git)?/?$",
)


def references(name: str) -> list[tuple[str, int]]:
    """Extract every issue and pull request number encoded in a worktree name."""
    found: list[tuple[str, int]] = []
    for kind, number in REFERENCE.findall(name.lower()):
        entry = (kind, int(number))
        if entry not in found:
            found.append(entry)
    return found


def repository(path: Path, *, timeout: int = 60) -> str | None:
    status, url = git(path, "remote", "get-url", "origin", timeout=timeout)
    match = REMOTE_SLUG.search(url.strip()) if status == 0 and url else None
    return match.group(1) if match else None


@dataclass(frozen=True)
class Query:
    """Where to ask whether a reference has finished, and what was already asked."""

    slug: str
    cache: dict
    timeout: int = 60


def reference_finished(kind: str, number: int, query: Query) -> tuple[bool, str]:
    """Report whether one reference is finished: an issue closed, or a merge.

    A pull request closed without merging is not finished work, so only MERGED
    authorizes removal.
    """
    key = (kind, number, query.slug)
    if key not in query.cache:
        noun, done = ("issue", "CLOSED") if kind == "gh" else ("pr", "MERGED")
        # Qualify the host: a bare slug follows GH_HOST, so an enterprise item with
        # the same slug and number could answer for the github.com one.
        status, output = run(
            ["gh", noun, "view", str(number), "--repo", f"github.com/{query.slug}",
             "--json", "state"],
            timeout=query.timeout,
        )
        state = json.loads(output).get("state") if status == 0 and output else None
        query.cache[key] = (state == done, f"{noun}-{number}-{str(state).lower()}")
    return query.cache[key]


BATCH_SIZE = 20

# Marker written by full-loop-helper-merge-cleanup.sh to defer cleanup to a
# supervisor; framework state, not work. Porcelain status of it when untracked.
DEFERRED_MARKER = ".agents/.full-loop-cleanup-deferred"
DEFERRED_MARKER_STATUS = f"?? {DEFERRED_MARKER}"


def _batch_query(items: list[tuple[str, int]]) -> str:
    """Build the batch query; the owner and name stay variables, never query text.

    Aliases interpolate safely because REFERENCE yields only digits, but a slug can
    carry a quote, and a slug parsed as query syntax is an injection.
    """
    fields = " ".join(
        f"{'g' if kind == 'gh' else 'p'}{number}: "
        f"{'issue' if kind == 'gh' else 'pullRequest'}(number: {number}) {{ state }}"
        for kind, number in items)
    return ("query($owner: String!, $name: String!) "
            f"{{ repository(owner: $owner, name: $name) {{ {fields} }} }}")


def _fill_batch(slug: str, items: list[tuple[str, int]], cache: dict, timeout: int) -> None:
    """Resolve one batch into the cache; absent aliases stay for the fallback.

    A batch naming a nonexistent number exits non-zero yet still returns the
    resolved aliases, so stdout is parsed regardless of the exit status.
    """
    owner, name = slug.split("/", 1)
    _, output = run(["gh", "api", "graphql", "--hostname", "github.com",
                     "-f", f"owner={owner}", "-f", f"name={name}",
                     "-f", f"query={_batch_query(items)}"], timeout=timeout)
    try:
        data = ((json.loads(output) or {}).get("data") or {}).get("repository") or {}
    except (ValueError, AttributeError):
        return
    for kind, number in items:
        node = data.get(f"{'g' if kind == 'gh' else 'p'}{number}")
        state = node.get("state") if isinstance(node, dict) else None
        if not isinstance(state, str):
            continue
        noun, done = ("issue", "CLOSED") if kind == "gh" else ("pr", "MERGED")
        cache[(kind, number, slug)] = (state == done, f"{noun}-{number}-{state.lower()}")


def _uncapped() -> float:
    """Stand in for a caller that tracks no budget, so ``cap`` alone bounds a batch."""
    return float("inf")


def prefetch(wanted: dict[str, list[tuple[str, int]]], cache: dict,
             *, remaining: Callable[[], float] = _uncapped, cap: int = 60) -> None:
    """Fill the cache ``reference_finished`` reads, one query per 20 references.

    ``remaining`` reports the caller's live budget, which batches share with the
    git and reference calls: a stalled batch returns empty instead of raising, so
    a per-batch timeout would let one slow repository spend the whole pass share.
    Any failure leaves the key absent, so judgement degrades to per-reference
    queries, and a reference still unresolved refuses rather than authorizing.
    """
    for slug, items in wanted.items():
        pending = [item for item in dict.fromkeys(items)
                   if (item[0], item[1], slug) not in cache]
        for start in range(0, len(pending), BATCH_SIZE):
            budget = int(min(remaining(), cap))
            if budget < 1:
                return
            _fill_batch(slug, pending[start:start + BATCH_SIZE], cache, budget)


def nothing_to_lose(path: Path, *, timeout: int = 60) -> tuple[bool, str]:
    """Confirm no uncommitted, untracked, or unpushed work exists in the worktree.

    Untracked and submodule reporting are requested explicitly: repository or
    global configuration can otherwise suppress exactly the files that removal
    would discard. Ignored build artifacts stay excluded and expected.
    """
    status, dirty = git(path, "status", "--porcelain", "-z", "--untracked-files=all",
                        "--ignore-submodules=none", timeout=timeout)
    if status != 0:
        return False, "status-unreadable"
    # Only the untracked deferral marker is framework state; a tracked change to
    # that path reports a different status code and still refuses.
    if any(entry and entry != DEFERRED_MARKER_STATUS for entry in dirty.split("\0")):
        return False, "uncommitted-changes"
    status, unpushed = git(path, "rev-list", "--count", "HEAD", "--not", "--remotes",
                           timeout=timeout)
    if status != 0 or not unpushed.isdigit():
        return False, "unpushed-state-unreadable"
    return (unpushed == "0"), ("nothing-to-lose" if unpushed == "0"
                               else f"unpushed-commits-{unpushed}")


def _preconditions(path: Path, census: Census | None) -> str | None:
    """Name the first missing precondition for judging this path at all."""
    failures = (
        (census is None, "process-inventory-unavailable"),
        (path.is_symlink(), "symlinked-path"),
        (metadata_directory(path) is None, "not-a-linked-worktree"),
        (locked(path), "worktree-locked"),
    )
    return next((reason for failed, reason in failures if failed), None)


def _identity(path: Path, found: list[tuple[str, int]], verdict: dict,
              timeout: int) -> str | None:
    """Record the repository and references a decision needs, naming what is absent."""
    slug = repository(path, timeout=timeout)
    if slug is None:
        return "repository-unknown"
    verdict["repository"] = slug
    verdict["references"] = [f"{kind}{number}" for kind, number in found]
    return None if found else "reference-unknown"


def _unfinished(found: list[tuple[str, int]], query: Query) -> str | None:
    """Name the first reference whose work has not finished."""
    for kind, number in found:
        finished, detail = reference_finished(kind, number, query)
        if not finished:
            return detail
    return None


def _unsafe_to_remove(path: Path, census: Census, timeout: int) -> str | None:
    """Name what removal would disturb or discard, or nothing when it is safe."""
    if census.holds(path):
        return "writers-present"
    clean, detail = nothing_to_lose(path, timeout=timeout)
    return None if clean else detail


def evidence(path: Path, census: Census | None, cache: dict,
             *, timeout: int = 60) -> dict:
    """Decide one worktree, reporting the first missing proof as the reason."""
    verdict: dict = {"path": str(path), "authorized": False, "reason": "unevaluated"}
    found = references(path.name)
    reason = _preconditions(path, census)
    if reason is None:
        reason = _identity(path, found, verdict, timeout)
    if reason is None:
        reason = _unfinished(found, Query(verdict["repository"], cache, timeout))
    if reason is None and census is not None:
        reason = _unsafe_to_remove(path, census, timeout)
    verdict["authorized"] = reason is None
    verdict["reason"] = reason or "work-finished"
    return verdict
