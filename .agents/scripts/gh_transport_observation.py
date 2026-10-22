# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validate authoritative GitHub quota headers without changing budget state."""

from __future__ import annotations


def valid_observation(headers: dict[str, str], resource: str, now: float):
    """Return (remaining, reset, limit) from authoritative headers, else None."""
    remaining = headers.get("x-ratelimit-remaining", "")
    reset = headers.get("x-ratelimit-reset", "")
    limit = headers.get("x-ratelimit-limit", "")
    if headers.get("x-ratelimit-resource", "") != resource:
        return None
    if not (remaining.isdecimal() and limit.isdecimal() and reset.isdecimal()):
        return None
    if not 0 <= int(remaining) <= int(limit) <= 1000000:
        return None
    if not now < int(reset) <= now + 86400:
        return None
    return int(remaining), int(reset), int(limit)
