#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Extract numeric GitHub rate headers while suppressing GH_DEBUG payloads."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import List, Optional, Tuple

from gh_quota_debug_cache import (
    CACHE_HOST as CACHE_HOST,
    CACHE_MIN_AGE_SECONDS as CACHE_MIN_AGE_SECONDS,
    CACHE_RESET_GRACE_SECONDS as CACHE_RESET_GRACE_SECONDS,
    CACHE_TTL_GRACE_SECONDS as CACHE_TTL_GRACE_SECONDS,
    CacheRequest as CacheRequest,
    DURATION_MS_FACTORS,
    DURATION_SECONDS_FACTORS as DURATION_SECONDS_FACTORS,
    GO_DURATION_COMPONENT as GO_DURATION_COMPONENT,
    REQUEST_START,
    _cache_request,
    _consume_proven_cache_hit,
    _go_duration_seconds as _go_duration_seconds,
    _request_header as _request_header,
    _request_time as _request_time,
)
from gh_quota_debug_response import REQUEST_END, response_metadata


def _request_ranges(lines: List[bytes]) -> List[Tuple[int, int]]:
    """Find half-open private request ranges, including unterminated frames."""
    starts = [index for index, line in enumerate(lines) if REQUEST_START.match(line)]
    ranges: List[Tuple[int, int]] = []
    for position, start in enumerate(starts):
        bound = starts[position + 1] if position + 1 < len(starts) else len(lines)
        ends = [
            index
            for index in range(start, bound)
            if REQUEST_END.match(lines[index].rstrip(b"\r\n"))
        ]
        # An unterminated debug frame is private too. Suppress it through the
        # next request frame (or EOF) instead of risking response-body leakage.
        end = ends[-1] + 1 if ends else bound
        ranges.append((start, end))
    return ranges


def _completion_ranges(lines: List[bytes]) -> List[Tuple[int, int]]:
    """Find half-open completion ranges while tracking pending request starts."""
    ranges: List[Tuple[int, int]] = []
    start: Optional[int] = None
    pending_requests = 0
    for index, line in enumerate(lines):
        if REQUEST_START.match(line):
            if pending_requests == 0:
                start = index
            pending_requests += 1
        if not REQUEST_END.match(line.rstrip(b"\r\n")) or pending_requests == 0:
            continue
        if start is None:
            continue
        ranges.append((start, index + 1))
        pending_requests -= 1
        start = index + 1 if pending_requests else None
    return ranges


def _duration(frame: List[bytes]) -> Optional[Tuple[float, bytes]]:
    """Return the last completion's duration value and unit, or None."""
    for line in reversed(frame):
        match = REQUEST_END.match(line.rstrip(b"\r\n"))
        if not match:
            continue
        return float(match.group(1)), match.group(2)
    return None


def _duration_ms(frame: List[bytes]) -> Optional[int]:
    """Convert a supported completion duration to nonnegative milliseconds."""
    duration = _duration(frame)
    if duration is None:
        return None
    value, unit = duration
    factor = DURATION_MS_FACTORS.get(unit)
    if factor is None:
        return None
    return max(0, round(value * factor))


def _write_sanitized_stderr() -> None:
    """Suppress all captured stderr until native diagnostics can be allowlisted."""
    # Exact-capture mode deliberately enables GH_DEBUG. Framing proves which
    # bytes belong to private request/response blocks, but it cannot prove that
    # bytes outside those blocks are diagnostics rather than malformed private
    # payloads. Until native diagnostics have a strict allowlist, suppress every
    # line instead of forwarding unframed content.
    return


UNKNOWN_METADATA = ("unknown", "unknown")
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


def _request_metadata(frame: List[bytes]) -> Tuple[str, str]:
    """Keep only allowlisted labels; never retain a path or request argument."""
    requests = [line for line in frame if line.startswith(b"> ") and b" HTTP/" in line]
    starts = sum(bool(REQUEST_START.match(line)) for line in frame)
    # Interleaved starts/completions cannot prove response ownership.
    match = REQUEST_LINE.fullmatch(requests[0]) if starts == 1 and len(requests) == 1 else None
    if match is None:
        return UNKNOWN_METADATA
    return match.group(1).decode("ascii"), _endpoint_class(match.group(2))


def _transport_frames(lines: List[bytes], request_ranges: List[Tuple[int, int]]) -> list:
    """Build sanitized transport records, excluding proven local cache hits.

    Use unknown request labels when frame ownership is ambiguous and append
    placeholder records for requests without matching completions.
    """
    found = (_cache_request(lines[start:end]) for start, end in request_ranges)
    cache_requests = [request for request in found if request is not None]
    frames = []
    completion_ranges = _completion_ranges(lines)
    # Any overlapping or unterminated request makes stream ownership
    # ambiguous, including a later start before an earlier response ends.
    owned = request_ranges == completion_ranges
    for start, end in completion_ranges:
        frame = lines[start:end]
        status_count, response, response_cost = response_metadata(frame)
        duration = _duration_ms(frame)
        if status_count == 1 and duration is not None and _consume_proven_cache_hit(
            response, cache_requests
        ):
            continue
        metadata = _request_metadata(frame) if owned else UNKNOWN_METADATA
        frames.append((status_count, response, response_cost, duration, metadata))
    for _ in range(max(0, len(request_ranges) - len(completion_ranges))):
        frames.append((0, {}, None, None, UNKNOWN_METADATA))
    return frames


def _frame_row(frame_index: int, record: tuple) -> str:
    """Format a sanitized frame as TSV, using x for absent field values."""
    status_count, response, response_cost, duration, request_metadata = record
    values = [
        "frame",
        str(frame_index),
        str(status_count),
        response.get("status", ""),
        response.get("resource", ""),
        response.get("used", ""),
        response.get("remaining", ""),
        response.get("reset", ""),
        "" if duration is None else str(duration),
        "" if response_cost is None else str(response_cost),
        *request_metadata,
    ]
    return "\t".join(value or "x" for value in values)


def main() -> int:
    """Read one debug capture and emit sanitized frame rows or an invalid marker.

    Return 2 for incorrect arguments, 1 for an unreadable capture, and 0 after
    emitting the capture result. Captured stderr is never forwarded.
    """
    if len(sys.argv) != 2:
        return 2
    try:
        data = Path(sys.argv[1]).read_bytes()
    except OSError:
        return 1
    lines = data.splitlines(keepends=True)
    request_ranges = _request_ranges(lines)
    _write_sanitized_stderr()
    if data and not request_ranges:
        # Non-empty stderr without a recognized request frame may be a changed
        # GH_DEBUG format containing private request or response data. Keep it
        # suppressed and mark capture invalid rather than claiming no request.
        print("v1\tinvalid")
        return 0
    frames = _transport_frames(lines, request_ranges)
    print(f"v1\t{len(frames)}")
    for frame_index, record in enumerate(frames, start=1):
        print(_frame_row(frame_index, record))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
