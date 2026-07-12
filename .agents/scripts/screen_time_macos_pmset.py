"""Permission-free macOS display-state collection from ``pmset -g log``."""

from __future__ import annotations

import datetime as dt
import os
import subprocess
from pathlib import Path

from screen_time_interval_common import WINDOWS, state_intervals


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


def parse_pmset_events(output):
    events = []
    for line in output.splitlines():
        if "Display is turned on" in line:
            state = True
        elif "Display is turned off" in line:
            state = False
        else:
            continue
        try:
            timestamp = dt.datetime.strptime(line[:25], "%Y-%m-%d %H:%M:%S %z").timestamp()
        except (ValueError, OverflowError, OSError):
            continue
        events.append((timestamp, state))
    return sorted(set(events))


def pmset_collection(now):
    output, error = read_pmset_log()
    if error:
        return {"status": "unavailable", "source": "macos-pmset-display-log", "reason": error, "intervals": []}
    events = parse_pmset_events(output)
    if not events:
        return {"status": "unavailable", "source": "macos-pmset-display-log", "reason": "no-display-events", "intervals": []}
    intervals = state_intervals(events, now - WINDOWS["year"], now)
    latest = events[-1][0]
    freshness = max(0.0, (now - latest) / 3600)
    return {
        "status": "stale" if freshness > 72 else "ok",
        "source": "macos-pmset-display-log",
        "reason": "permission-free-display-state-events",
        "intervals": intervals,
        "observations": len(events),
        "latest_epoch": latest,
        "earliest_epoch": events[0][0],
        "observation_epochs": [timestamp for timestamp, _ in events],
        "coverage_start_epoch": events[0][0],
        "coverage_end_epoch": now if events[-1][1] else latest,
        "freshness_hours": round(freshness, 1),
    }
