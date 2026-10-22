# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validate quota responses and reconcile their conservative admission balance."""

from __future__ import annotations

from typing import NamedTuple

from gh_transport_recovery import note_live_window, probe_recovers


class QuotaResponse(NamedTuple):
    """One validated quota observation with its response headers and receipt time."""

    observed: tuple[int, int]
    headers: dict[str, str]
    now: float


def accepted_balance(budget, reservation: str, resource: str, row,
                     response: QuotaResponse) -> tuple[int, int, float, bool]:
    """Reconcile a valid response inside the caller's existing transaction."""
    observed, headers, now = response
    available, reset_at = observed
    blocked_until = 0.0
    # A bound credential's newer window or a serialized reserve
    # probe may repair stale evidence. Shared/ambiguous owners and
    # same-window late replies retain conservative accounting.
    # /rate_limit is never a grant.
    recovered = probe_recovers(budget, reservation, resource, row, reset_at)
    if row and row[1] > now and not recovered:
        # Late responses and unresolved owners with different reset
        # epochs cannot restore quota observed to have been spent.
        # Keep the lower balance paired with its own reset epoch:
        # extending it to another credential's later (sliding)
        # reset would re-stamp stale debt indefinitely (GH#33701).
        if reset_at > row[1]:
            note_live_window(budget, resource, reset_at, now)
        if available >= row[0]:
            available, reset_at = row[0], int(row[1])
        blocked_until = row[3]
    retry_after = headers.get("retry-after", "")
    if retry_after.isdecimal():
        blocked_until = max(blocked_until, now + int(retry_after))
    if available == 0:
        blocked_until = max(blocked_until, reset_at)
    return available, reset_at, blocked_until, recovered


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
