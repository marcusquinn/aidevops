#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Advisory checkpoint health from trusted, immutable release evidence."""

from __future__ import annotations

import datetime as dt
import re
import time
from dataclasses import dataclass
from functools import lru_cache
from typing import Any, Callable, Optional


@dataclass(frozen=True)
class CheckpointContext:
    slug: str
    run_gh_json: Callable[[list[str]], Any]


@lru_cache(maxsize=None)
def _checkpoint_health_writer(context: CheckpointContext, login: str) -> bool:
    """Resolve ambiguous associations once without changing dispatch authority."""
    if not re.fullmatch(r"[A-Za-z0-9-]{1,39}", login):
        return False
    result = context.run_gh_json(
        ["gh", "api", f"repos/{context.slug}/collaborators/{login}/permission"])
    return isinstance(result, dict) and result.get("permission") in {"write", "maintain", "admin"}


def _trusted_events(comments: list[dict[str, Any]], context: CheckpointContext) -> list:
    events = []
    for comment in comments:
        lines = [line for line in str(comment.get("body") or "").splitlines()
                 if line.startswith(("CLAIM_RELEASED ", "DISPATCH_CLAIM ",
                                     "Dispatching worker", "Interactive claim"))]
        if not lines:
            continue
        # #aidevops:trust-boundary — association alone does not make a
        # COLLABORATOR or cross-org runner authoritative.
        if (comment.get("author_association") not in {"OWNER", "MEMBER"} and
                not _checkpoint_health_writer(context, (comment.get("user") or {}).get("login", ""))):
            continue
        events.extend((comment, line) for line in lines)
    return events


def _is_unknown_release(comment: dict[str, Any], line: str) -> bool:
    if not line.startswith("CLAIM_RELEASED reason=blocked "):
        return False
    if ("Terminal blocker: reason=unknown owner=worker-triage " not in str(comment.get("body")) or
            comment.get("updated_at", comment.get("created_at")) != comment.get("created_at")):
        return False
    runner = re.search(r"(?:^| )runner=([A-Za-z0-9-]+)(?: |$)", line)
    return bool(runner and runner.group(1) == (comment.get("user") or {}).get("login"))


def _release_age(comment: dict[str, Any], now: dt.datetime) -> int:
    released = dt.datetime.fromisoformat(comment["created_at"].replace("Z", "+00:00"))
    return int((now - released).total_seconds() // 60)


def _latest_unknown_age(events: list, now: dt.datetime) -> Optional[int]:
    if not events:
        return None
    comment, line = max(events, key=lambda event: event[0].get("id", 0))
    return _release_age(comment, now) if _is_unknown_release(comment, line) else None


def _unowned_blocked_issue(issue: dict[str, Any]) -> bool:
    labels = issue.get("labels", [])
    if not isinstance(labels, list):
        return False
    names = {str(label.get("name") or "") for label in labels if isinstance(label, dict)}
    return "status:blocked" in names and not issue.get("assignees")


def _read_comments(context: CheckpointContext, number: int) -> Optional[list[dict[str, Any]]]:
    pages = context.run_gh_json(["gh", "api", "--paginate", "--slurp",
                                f"repos/{context.slug}/issues/{number}/comments?per_page=100"])
    if not isinstance(pages, list):
        return None
    return [comment for page in pages for comment in
            (page if isinstance(page, list) else [page]) if isinstance(comment, dict)]


def count_unknown_triage(aggregate: dict[str, int], issue: dict[str, Any],
                         now: dt.datetime, context: CheckpointContext) -> None:
    """Count release age; keep unavailable evidence distinct from an empty queue."""
    if not _unowned_blocked_issue(issue):
        return
    number = issue.get("number")
    if not isinstance(number, int) or number < 1:
        return
    comments = _read_comments(context, number)
    if comments is None:
        aggregate["unknown_checkpoint_triage_unreadable"] += 1
        return
    try:
        age = _latest_unknown_age(_trusted_events(comments, context), now)
    except (KeyError, TypeError, ValueError):
        aggregate["unknown_checkpoint_triage_unreadable"] += 1
        return
    if age is not None and age >= 0:
        aggregate["unknown_checkpoint_triage"] += 1
        aggregate["oldest_unknown_checkpoint_triage_age_min"] = max(
            aggregate["oldest_unknown_checkpoint_triage_age_min"], age)


def enrich_repo(aggregate: dict[str, int], issues: list[dict[str, Any]],
                now: dt.datetime, context: CheckpointContext, deadline: float) -> None:
    """Use only the budget remaining after all repositories' durable progress."""
    for issue in issues:
        if time.monotonic() < deadline:
            count_unknown_triage(aggregate, issue, now, context)
        elif _unowned_blocked_issue(issue):
            aggregate["unknown_checkpoint_triage_unreadable"] += 1
