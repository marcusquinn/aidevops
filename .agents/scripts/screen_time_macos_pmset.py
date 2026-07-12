"""Permission-free macOS display-state collection from ``pmset -g log``."""

from __future__ import annotations

import datetime as dt
import os
import re
import subprocess
from pathlib import Path

from screen_time_interval_common import WINDOWS, union_intervals

DISPLAY_ASSERTION = re.compile(
    r'"Powerd - Prevent sleep while display is on"\s+(\d{2}):(\d{2}):(\d{2})\s+id:'
)


def read_pmset_log():
    fixture = os.environ.get("AIDEVOPS_PMSET_FIXTURE")
    if fixture:
        try:
            return Path(fixture).read_text(encoding="utf-8"), None
        except OSError as exc:
            return "", f"fixture-read-failed:{type(exc).__name__}"
    try:
        result = subprocess.run(  # nosec B603
            ["pmset", "-g", "log"], check=False, capture_output=True, text=True, timeout=15
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return "", f"pmset-failed:{type(exc).__name__}"
    if result.returncode != 0:
        return "", f"pmset-exit-{result.returncode}"
    return result.stdout, None


def parse_pmset_assertion_intervals(output, now):
    intervals = []
    for line in output.splitlines():
        match = DISPLAY_ASSERTION.search(line)
        if not match:
            continue
        try:
            end = dt.datetime.strptime(line[:25], "%Y-%m-%d %H:%M:%S %z").timestamp()
        except (ValueError, OverflowError, OSError):
            continue
        hours, minutes, seconds = (int(value) for value in match.groups())
        duration = hours * 3600 + minutes * 60 + seconds
        if duration > 0 and end <= now:
            intervals.append((end - duration, end))
    return union_intervals(intervals, now - WINDOWS["year"], now)


def pmset_collection(now):
    output, error = read_pmset_log()
    if error:
        return {"status": "unavailable", "source": "macos-pmset-display-assertions", "reason": error, "intervals": []}
    intervals = parse_pmset_assertion_intervals(output, now)
    if not intervals:
        return {"status": "unavailable", "source": "macos-pmset-display-assertions", "reason": "no-display-assertions", "intervals": []}
    latest = max(right for _, right in intervals)
    earliest = min(left for left, _ in intervals)
    freshness = max(0.0, (now - latest) / 3600)
    return {
        "status": "stale" if freshness > 72 else "ok",
        "source": "macos-pmset-display-assertions",
        "reason": "permission-free-duration-bearing-display-assertions",
        "intervals": intervals,
        "observations": len(intervals),
        "latest_epoch": latest,
        "earliest_epoch": earliest,
        "observation_epochs": [right for _, right in intervals],
        "coverage_start_epoch": earliest,
        "coverage_end_epoch": latest,
        "freshness_hours": round(freshness, 1),
    }
