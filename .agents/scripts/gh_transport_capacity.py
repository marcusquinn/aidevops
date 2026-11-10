# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Capacity-based local REST admission, not a reserved slice of primary quota.

GitHub's secondary ceilings are 100 concurrent requests and 900 REST points/min.
This history covers supported one-point GETs only, not opaque native commands or
other machines. Server cooldowns remain authoritative for those shared consumers.
"""

import os


PRIMARY_PACING = "local primary pacing: time to reset divided by remaining quota"
# Short parallel bursts may run ahead of the even schedule by at most this many
# admissions at full quota. The allowance shrinks with the remaining share, so
# a scarce window is spaced strictly rather than spent in one burst.
PACING_BURST = 10
# GH#37570: low-volume, latency-sensitive reads (the worker-bus relay delivering
# human feedback to live workers) opt in with AIDEVOPS_GH_ADMISSION_CLASS. Bulk
# demand keeps the shared slot ahead of any short admission wait, so without a
# class those reads were deferred almost every cycle. The exemption covers only
# the even-spacing schedule, and only while the available share is at least
# 1/DELIVERY_FLOOR_DIVISOR of the window; scarce windows pace every caller.
DELIVERY_CLASS = "delivery"
DELIVERY_FLOOR_DIVISOR = 4


def delivery_exempt(row, reserved):
    """True when a delivery-class read may skip primary pacing."""
    if os.environ.get("AIDEVOPS_GH_ADMISSION_CLASS", "") != DELIVERY_CLASS:
        return False
    limit = row[4] if row[4] and row[4] > 0 else row[0]
    # Ceiling division: a 30-point search window needs 8 usable points, not 7.
    return row[0] - reserved >= max(1, -(-limit // DELIVERY_FLOOR_DIVISOR))


def capacity_wait(budget, resource, row, reserved, now):
    """Return (reason, retry_at); caller holds the admission transaction."""
    budget.db.execute("DELETE FROM admission_history WHERE started<=?", (now - 60,))
    active = budget.db.execute(
        "SELECT COUNT(*) FROM reservation WHERE scope=? AND uncertain=0",
        (budget.scope,),
    ).fetchone()[0]
    if active >= 100:
        return "local REST concurrency at GitHub secondary ceiling", now + 0.1
    count, oldest = budget.db.execute(
        "SELECT COUNT(*),MIN(started) FROM admission_history WHERE scope=?",
        (budget.scope,),
    ).fetchone()
    if count >= 900:
        return "local REST points at GitHub secondary ceiling", oldest + 60
    if not row or row[1] <= now or row[2] > now:
        return "", now
    # Delivery reads leave the shared slot untouched; their spend still lowers
    # the server-reported remaining, which tightens the bulk interval.
    if delivery_exempt(row, reserved):
        return "", now
    return primary_wait(budget, resource, row, reserved, now)


def primary_wait(budget, resource, row, reserved, now):
    """Space admissions evenly: interval = seconds to reset / usable points.

    A GCRA-style schedule: pacing.retry_at holds the next on-schedule slot.
    Server-reported remaining already includes spend by ungoverned commands and
    other hosts on the same credential, so the interval tightens automatically
    when that spend drains the window. Idle time is not banked beyond the burst
    allowance; it lowers the interval instead because more points remain.
    """
    available = row[0] - reserved
    # Do not turn pacing into a final-point reserve. Atomic admission still
    # prevents overspend and secondary limits still apply above this boundary.
    if available <= 1:
        return "", now
    interval = (row[1] - now) / available
    limit = row[4] if row[4] and row[4] > 0 else row[0]
    ahead = max(1, min(PACING_BURST, available, -(-available * PACING_BURST // limit))) - 1
    saved = budget.db.execute(
        "SELECT reset,retry_at,remaining FROM pacing WHERE scope=? AND resource=?",
        (budget.scope, resource),
    ).fetchone()
    # A new window or a higher authoritative balance starts a fresh schedule.
    slot = max(now, saved[1]) if saved and saved[0] == row[1] and row[0] <= saved[2] else now
    if slot - ahead * interval > now:
        # The allowance shrinks as reset nears, so solve t = slot - ahead *
        # (reset - t) / available instead of returning a deadline that would
        # itself be deferred again by the smaller interval at t.
        return PRIMARY_PACING, (slot * available - ahead * row[1]) / (available - ahead)
    budget.db.execute("INSERT OR REPLACE INTO pacing VALUES(?,?,?,?,?)",
                      (budget.scope, resource, row[1], slot + interval, row[0]))
    return "", now
