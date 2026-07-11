"""Shared, defensive interval primitives for screen-time collectors."""

from __future__ import annotations

import datetime as dt
import math

CORE_DATA_EPOCH = 978307200
DAY = 86400
WINDOWS = {"day": DAY, "week": 7 * DAY, "month": 28 * DAY, "year": 365 * DAY}


def safe_float(value):
    if isinstance(value, bool):
        return None
    try:
        converted = float(value)
    except (TypeError, ValueError, OverflowError):
        return None
    return converted if math.isfinite(converted) else None


def local_date(timestamp):
    converted = safe_float(timestamp)
    if converted is None:
        return None
    try:
        return dt.datetime.fromtimestamp(converted).date()
    except (OSError, OverflowError, ValueError):
        return None


def local_midnight_epoch(date):
    try:
        return dt.datetime.combine(date, dt.time.min).timestamp()
    except (OSError, OverflowError, TypeError, ValueError):
        return None


def local_day_bounds(date):
    start = local_midnight_epoch(date)
    end = local_midnight_epoch(date + dt.timedelta(days=1)) if start is not None else None
    return (start, end) if end is not None else (None, None)


def safe_core_epoch(value):
    converted = safe_float(value)
    if converted is None:
        return None
    epoch = converted + CORE_DATA_EPOCH
    return epoch if local_date(epoch) is not None else None


def clip_interval(interval, start, end):
    if not isinstance(interval, (tuple, list)) or len(interval) != 2:
        return None
    left = safe_float(interval[0])
    right = safe_float(interval[1])
    if left is None or right is None or right <= left:
        return None
    if right <= start or left >= end:
        return None
    return max(start, left), min(end, right)


def union_intervals(intervals, start, end):
    clipped = []
    for interval in intervals:
        candidate = clip_interval(interval, start, end)
        if candidate is not None:
            clipped.append(candidate)
    merged = []
    for left, right in sorted(clipped):
        if merged and left <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], right))
        else:
            merged.append((left, right))
    return merged


def interval_seconds(intervals, start, end):
    total = sum(right - left for left, right in union_intervals(intervals, start, end))
    return min(end - start, total)


def apply_state_event(state, opened, event, start):
    timestamp, new_state = event
    if timestamp < start:
        return new_state, start if new_state else None, None
    if new_state == state:
        return state, opened, None
    closed = (opened, timestamp) if state and opened is not None else None
    return new_state, timestamp if new_state else None, closed


def state_intervals(events, start, end, initial=False):
    state = initial
    opened = start if state else None
    intervals = []
    for event in sorted(events):
        if event[0] > end:
            break
        state, opened, closed = apply_state_event(state, opened, event, start)
        if closed is not None:
            intervals.append(closed)
    if state and opened is not None and opened < end:
        intervals.append((opened, end))
    return union_intervals(intervals, start, end)


def parse_timestamp(value):
    try:
        normalized = str(value).strip().replace("Z", "+00:00")
        parsed = dt.datetime.fromisoformat(normalized)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed.timestamp()
    except (OSError, OverflowError, TypeError, ValueError):
        return None
