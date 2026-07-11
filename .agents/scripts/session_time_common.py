"""Shared interval and classification primitives for session aggregation."""

from __future__ import annotations

import re

DAY_MS = 86400000
WINDOWS = {
    "day": DAY_MS,
    "week": 7 * DAY_MS,
    "28d": 28 * DAY_MS,
    "month": 30 * DAY_MS,
    "quarter": 90 * DAY_MS,
    "year": 365 * DAY_MS,
}
WORKER_PATTERNS = [
    re.compile(pattern, re.I)
    for pattern in (
        r"^Issue #\d+", r"^PR #\d+", r"^Fix PR\b", r"^Review PR\b",
        r"^Supervisor Pulse", r"/full-loop", r"^dispatch:", r"^Worker:",
        r"^t\d+[.\-:]", r"^escalation-", r"^health-check$", r"failing CI\b",
        r"CI fail", r"CHANGES_REQUESTED", r"CodeRabbit review", r"address review",
        r"review feedback", r"^Fix qlty\b", r"^Gemini feedback\b",
        r"^observability-only headless session$",
    )
]
TEMP_PATHS = (
    re.compile(r"^/private/tmp/opencode(?:[.-].*)?$"),
    re.compile(r"^/tmp/opencode(?:[.-].*)?$"),
    re.compile(r"^/var/folders/.*/T/opencode.*$"),
)


def path_matches(candidate, root):
    if not root:
        return True
    if not candidate:
        return False
    suffix_match = candidate.startswith(root + ".") or candidate.startswith(root + "-")
    return candidate == root or candidate.startswith(root + "/") or suffix_match


def classify(title, directory):
    if any(pattern.search(directory or "") for pattern in TEMP_PATHS):
        return "worker"
    return "worker" if any(pattern.search(title or "") for pattern in WORKER_PATTERNS) else "interactive"


def clip_interval(interval, start, end):
    left, right = interval
    if right <= start or left >= end:
        return None
    return max(start, left), min(end, right)


def union(intervals, start, end):
    clipped = [candidate for item in intervals if (candidate := clip_interval(item, start, end)) is not None]
    result = []
    for left, right in sorted(clipped):
        if result and left <= result[-1][1]:
            result[-1] = (result[-1][0], max(result[-1][1], right))
        else:
            result.append((left, right))
    return result


def duration(intervals, start, end):
    return sum(right - left for left, right in union(intervals, start, end))


def safe_int(value):
    if isinstance(value, bool):
        return None
    try:
        return int(value)
    except (TypeError, ValueError, OverflowError):
        return None
