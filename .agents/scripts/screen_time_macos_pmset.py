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
HELD_DISPLAY_ASSERTION = re.compile(
    r'\]\s+(\d+):(\d{2}):(\d{2})\s+PreventUserIdleSystemSleep\s+named:\s+"Powerd - Prevent sleep while display is on"'
)


def read_fixture(path):
    try:
        return Path(path).read_text(encoding="utf-8"), None
    except OSError as exc:
        return "", f"fixture-read-failed:{type(exc).__name__}"


def run_pmset(arguments):
    try:
        result = subprocess.run(  # nosec B603
            ["pmset", *arguments], check=False, capture_output=True, text=True, timeout=15
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return "", f"pmset-failed:{type(exc).__name__}"
    if result.returncode != 0:
        return "", f"pmset-exit-{result.returncode}"
    return result.stdout, None


def read_pmset_log():
    fixture = os.environ.get("AIDEVOPS_PMSET_FIXTURE")
    return read_fixture(fixture) if fixture else run_pmset(["-g", "log"])


def read_held_assertions():
    """Live ``pmset -g assertions``; a log fixture alone means no live state."""
    fixture = os.environ.get("AIDEVOPS_PMSET_ASSERTIONS_FIXTURE")
    if fixture:
        return read_fixture(fixture)
    if os.environ.get("AIDEVOPS_PMSET_FIXTURE"):
        return "", None
    return run_pmset(["-g", "assertions"])


def parse_held_display_assertion(output, now):
    """The display assertion still held has no log line until it is released.

    Without it, a day snapshotted while the display is still on loses the open
    span permanently (2026-11-08 recorded 8.0h at 01:40Z; 12.4h once released).
    """
    intervals = []
    for line in output.splitlines():
        match = HELD_DISPLAY_ASSERTION.search(line)
        if not match:
            continue
        hours, minutes, seconds = (int(value) for value in match.groups())
        held = hours * 3600 + minutes * 60 + seconds
        if held > 0:
            intervals.append((now - held, now))
    return intervals


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
    held_output, _ = read_held_assertions()
    intervals = union_intervals(
        parse_pmset_assertion_intervals(output, now) + parse_held_display_assertion(held_output, now),
        now - WINDOWS["year"],
        now,
    )
    if error or not intervals:
        # Without the log, pmset alone is incomplete and stays unavailable; the
        # live held span is still returned for a readable Knowledge union.
        return {
            "status": "unavailable",
            "source": "macos-pmset-display-assertions",
            "reason": error or "no-display-assertions",
            "intervals": intervals,
        }
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
