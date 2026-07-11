"""Parse Linux wtmp login-session proxy observations."""

from __future__ import annotations

import datetime as dt
import re

from screen_time_interval_common import WINDOWS, union_intervals

LAST_DATE = re.compile(r"(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) [A-Z][a-z]{2}\s+[0-9]{1,2} [0-9:]{8}(?: [+-][0-9]{4})? [0-9]{4}")


def parse_last_local_timestamp(value):
    formats = ("%a %b %d %H:%M:%S %z %Y", "%a %b %d %H:%M:%S %Y")
    for format_string in formats:
        try:
            return dt.datetime.strptime(value, format_string).timestamp()
        except (OSError, OverflowError, ValueError):
            pass
    return None


def structured_interval(line):
    match = re.match(r"^([0-9]+)\|([0-9]+)$", line.strip())
    if not match:
        return None
    left, right = float(match.group(1)), float(match.group(2))
    return (left, right) if right > left else None


def dated_interval(line, now):
    dates = LAST_DATE.findall(line)
    if not dates:
        return None
    left = parse_last_local_timestamp(dates[0])
    right = now if "still logged in" in line else parse_last_local_timestamp(dates[1]) if len(dates) >= 2 else None
    return (left, right) if left is not None and right is not None and right > left else None


def parse_wtmp_line(line, now):
    ignored = not line.strip() or "wtmp begins" in line or line.startswith(("reboot", "shutdown"))
    if ignored:
        return None, False
    interval = structured_interval(line) or dated_interval(line, now)
    return interval, interval is None


def parse_lines(lines, now):
    intervals, skipped = [], 0
    for line in lines:
        interval, malformed = parse_wtmp_line(line, now)
        if interval is not None:
            intervals.append(interval)
        skipped += int(malformed)
    return intervals, skipped


def unavailable(reason):
    source = "linux-wtmp" if reason.startswith("fixture-read-failed:") else "linux-logind+wtmp"
    return {"status": "unavailable", "source": source, "reason": reason, "intervals": []}


def available(intervals, skipped, now, journal_reason):
    latest = max(right for _, right in intervals)
    freshness = max(0.0, (now - latest) / 3600)
    return {
        "status": "stale" if freshness > 72 else "ok",
        "source": "linux-wtmp:login-session-proxy",
        "reason": f"logind-unavailable:{journal_reason}",
        "intervals": union_intervals(intervals, now - WINDOWS["year"], now),
        "observations": len(intervals),
        "latest_epoch": latest,
        "earliest_epoch": min(left for left, _ in intervals),
        "freshness_hours": round(freshness, 1),
        "skipped_rows": skipped,
        "observation_epochs": [],
        "coverage_start_epoch": min(left for left, _ in intervals),
        "coverage_end_epoch": latest,
    }


def wtmp_payload(lines, error, now, journal_reason):
    if error:
        return unavailable(error)
    intervals, skipped = parse_lines(lines, now)
    if not intervals:
        return unavailable(f"{journal_reason};no-parseable-wtmp-sessions")
    return available(intervals, skipped, now, journal_reason)
