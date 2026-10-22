#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Prove local gh cache hits from request timing and retained response metadata."""

from __future__ import annotations

import re
from datetime import datetime
from email.utils import parsedate_to_datetime
from typing import Dict, List, Optional, Tuple


REQUEST_START = re.compile(
    rb"^\* Request at (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)? [+-]\d{4})"
)
GO_DURATION_COMPONENT = re.compile(
    rb"([0-9]+(?:\.[0-9]+)?)(ns|(?:\xc2\xb5|\xce\xbc|u)s|ms|s|m|h)"
)
DURATION_MS_FACTORS = {
    b"ns": 0.000001,
    b"us": 0.001,
    b"\xc2\xb5s": 0.001,
    b"\xce\xbcs": 0.001,
    b"ms": 1.0,
    b"s": 1000.0,
}
DURATION_SECONDS_FACTORS = {
    **{unit: factor / 1000 for unit, factor in DURATION_MS_FACTORS.items()},
    b"m": 60.0,
    b"h": 3600.0,
}
CACHE_HOST = b"api.github.com"
CACHE_MIN_AGE_SECONDS = 2.0
CACHE_TTL_GRACE_SECONDS = 5.0
CACHE_RESET_GRACE_SECONDS = 5.0
CacheRequest = Tuple[datetime, float]


def _request_header(frame: List[bytes], name: bytes) -> Optional[bytes]:
    prefix = b"> " + name.lower() + b":"
    for line in frame:
        stripped = line.rstrip(b"\r\n")
        if stripped.lower().startswith(prefix):
            return stripped.split(b":", 1)[1].strip()
    return None


def _go_duration_seconds(value: bytes) -> Optional[float]:
    offset = 0
    total = 0.0
    for match in GO_DURATION_COMPONENT.finditer(value):
        if match.start() != offset:
            return None
        factor = DURATION_SECONDS_FACTORS.get(match.group(2))
        if factor is None:
            return None
        total += float(match.group(1)) * factor
        offset = match.end()
    return total if offset == len(value) and offset > 0 else None


def _request_time(frame: List[bytes]) -> Optional[datetime]:
    if not frame:
        return None
    match = REQUEST_START.match(frame[0].rstrip(b"\r\n"))
    if match is None:
        return None
    value = match.group(1).decode("ascii", errors="ignore")
    time_format = (
        "%Y-%m-%d %H:%M:%S.%f %z" if "." in value else "%Y-%m-%d %H:%M:%S %z"
    )
    try:
        return datetime.strptime(value, time_format)
    except ValueError:
        return None


def _cache_request(frame: List[bytes]) -> Optional[CacheRequest]:
    if _request_header(frame, b"host") != CACHE_HOST:
        return None
    ttl_value = _request_header(frame, b"x-gh-cache-ttl")
    ttl_seconds = _go_duration_seconds(ttl_value) if ttl_value is not None else None
    request_time = _request_time(frame)
    if ttl_seconds is None or ttl_seconds <= 0 or request_time is None:
        return None
    return request_time, ttl_seconds


def _consume_proven_cache_hit(
    response: Dict[str, str], cache_requests: List[CacheRequest]
) -> bool:
    # go-gh's HTTP logger wraps its local cache RoundTripper, so cache hits emit
    # normal request/response blocks. Exclude one only when four independent
    # properties agree: github.com host, positive cache TTL, a persisted response
    # Date that is still inside that TTL, and a retained rate-window reset that
    # expired before this request. The expired reset is response-owned proof of
    # stale metadata and stays reliable when local cache work takes milliseconds
    # under load. Request and completion streams are matched by evidence count
    # because concurrent gh queries may interleave their starts before either
    # response is logged.
    try:
        reset_epoch = int(response.get("reset", ""))
    except ValueError:
        return False
    try:
        response_time = parsedate_to_datetime(response.get("date", ""))
        if response_time.tzinfo is None or response_time.utcoffset() is None:
            return False
    except (TypeError, ValueError):
        return False
    for index, (request_time, ttl_seconds) in enumerate(cache_requests):
        age_seconds = (request_time - response_time).total_seconds()
        reset_expired = (
            reset_epoch + CACHE_RESET_GRACE_SECONDS < request_time.timestamp()
        )
        if (
            CACHE_MIN_AGE_SECONDS < age_seconds <= ttl_seconds + CACHE_TTL_GRACE_SECONDS
            and reset_expired
        ):
            del cache_requests[index]
            return True
    return False
