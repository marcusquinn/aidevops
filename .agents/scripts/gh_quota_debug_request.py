#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Request-label classification for sanitized GitHub debug captures."""

from __future__ import annotations

import re
from typing import List, Tuple

from gh_quota_debug_cache import REQUEST_START

UNKNOWN_METADATA = ("unknown", "unknown", "unknown")
REQUEST_LINE = re.compile(
    rb"> (GET|HEAD|POST|PUT|PATCH|DELETE|OPTIONS) (/[^\s]*) HTTP/[0-9.]+\r?\n?"
)
ROOT_CLASSES = {
    b"rate_limit": "rate-limit",
    b"graphql": "graphql",
    b"search": "search",
    b"user": "users",
    b"users": "users",
    b"orgs": "orgs",
    b"notifications": "notifications",
    b"installation": "installation",
}
REPO_CLASSES = {
    b"issues": "repos-issues",
    b"pulls": "repos-pulls",
    b"actions": "repos-actions",
    b"commits": "repos-commits",
    b"git": "repos-git",
    b"contents": "repos-contents",
    b"releases": "repos-releases",
    b"check-runs": "repos-checks",
    b"check-suites": "repos-checks",
    b"statuses": "repos-statuses",
}


def _endpoint_class(target: bytes) -> str:
    """Map a request target to a static label; the target itself is discarded."""
    parts = target.split(b"?", 1)[0].split(b"#", 1)[0].strip(b"/").split(b"/")
    if parts[0] != b"repos":
        return ROOT_CLASSES.get(parts[0], "other")
    if len(parts) <= 3:
        return "repos-other"
    return REPO_CLASSES.get(parts[3], "repos-other")


def _endpoint_family(target: bytes) -> str:
    """Discard identifiers and queries, returning only a static endpoint family."""
    path = target.split(b"?", 1)[0].split(b"#", 1)[0].strip(b"/")
    if path == b"user":
        return "user"
    if re.fullmatch(rb"repos/[^/]+/[^/]+/collaborators/[^/]+/permission", path):
        return "repos/:o/:r/collaborators/:u/permission"
    # Only static alternatives are captured. Identifier groups contribute a
    # presence bit, never their text; unknown/deeper suffixes remain discarded.
    match = re.match(rb"repos/[^/]+/[^/]+/(" + b"|".join(REPO_CLASSES) +
                     rb")(?:$|(/[^/]+)(?:/(reviews|comments|commits|files|checks|runs)(?:/|$))?)", path)
    if match:
        return ("repos/:o/:r/" + match[1].decode("ascii") +
                "/:id" * bool(match[2]) + "/" + (match[3] or b"").decode("ascii")).rstrip("/")
    return _endpoint_class(target)


def _request_metadata(frame: List[bytes]) -> Tuple[str, str, str]:
    """Keep only allowlisted labels; never retain a path or request argument."""
    requests = [line for line in frame if line.startswith(b"> ") and b" HTTP/" in line]
    starts = sum(bool(REQUEST_START.match(line.rstrip(b"\r\n"))) for line in frame)
    # Interleaved starts/completions cannot prove response ownership.
    match = REQUEST_LINE.fullmatch(requests[0]) if starts == 1 and len(requests) == 1 else None
    if match is None:
        return UNKNOWN_METADATA
    return match.group(1).decode("ascii"), _endpoint_class(match.group(2)), _endpoint_family(match.group(2))
