"""Worker slot intervals from spawn, exit and host-boot evidence."""
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

from bisect import bisect_right
from datetime import datetime, timezone
import math
import statistics
import sys
import time

from pulse_throughput_metrics import sample_intervals

# Shared with dispatch_metrics/pulse_metrics look-back and look-ahead bounds.
PAIRING_WINDOW_SECONDS = 21600


def pair_workers(spawns, exits, since, until):
    """Pair each exit with the latest same-issue spawn at or before it.

    Exits before the window still consume their spawn, so open_intervals does
    not mistake an already-finished worker for a running one. Returns paired
    intervals, in-window runtimes, the paired keys and the longest pairing.
    """
    intervals = []
    paired = set()
    runtimes = []
    longest = 0
    for timestamp, issue in sorted(exits):
        candidates = spawns.get(issue, [])
        # bisect_right: a same-second completion consumes its spawn, so it
        # never becomes an open interval.
        index = bisect_right(candidates, timestamp) - 1
        start = candidates[index] if index >= 0 else None
        if start is None or timestamp - start > PAIRING_WINDOW_SECONDS or (issue, start) in paired:
            continue
        paired.add((issue, start))
        longest = max(longest, timestamp - start)
        if since <= timestamp < until:
            runtimes.append((timestamp - start) / 60)
        if start < until and timestamp > since:
            intervals.append((start, timestamp))
    return intervals, runtimes, paired, longest or PAIRING_WINDOW_SECONDS


def host_boot_time(now):
    """Latest boot from a clock that keeps counting during sleep, else None."""
    clock = getattr(time, "CLOCK_BOOTTIME", None)
    if clock is None and sys.platform == "darwin":
        clock = time.CLOCK_MONOTONIC  # macOS: continues while asleep.
    try:
        return now - time.clock_gettime(clock) if clock is not None else None
    except OSError:
        return None


def _cutoff(start, cutoffs):
    now, bound, boot = cutoffs
    lost_at_boot = boot if boot is not None and start < boot else math.inf
    return min(start + bound, lost_at_boot, now)


def open_intervals(spawns, paired, window, cutoffs):
    """Spawns without an exit record: still running, or lost without one.

    window is (since, until); cutoffs is (now, longest paired runtime, latest
    host boot or None). Each interval ends at the next same-issue spawn or the
    first cutoff.
    """
    since, until = window
    inferred = []
    for issue, starts in spawns.items():
        for start, following in zip(starts, starts[1:] + [math.inf]):
            if start < until and (issue, start) not in paired:
                inferred.append((start, min(following, _cutoff(start, cutoffs))))
    return [(start, end) for start, end in inferred if end > max(since, start)]


def occupancy_summary(intervals, since, until):
    samples = list(sample_intervals(intervals, since, until, 300)) if intervals else []
    return {"sample_seconds": 300, "mean": statistics.mean(samples) if samples else None,
            "max": max(samples) if samples else None}


def occupancy_metrics(spawns, exits, window, now):
    """Return in-window runtimes, occupancy with open intervals, and paired-only."""
    since, until = window
    intervals, runtimes, paired, bound = pair_workers(spawns, exits, since, until)
    boot = host_boot_time(now)
    inferred = open_intervals(spawns, paired, window, (now, bound, boot))
    boot_iso = datetime.fromtimestamp(round(boot), timezone.utc).isoformat() if boot else None
    occupancy = {**occupancy_summary(intervals + inferred, since, until), "open_intervals": len(inferred),
                 "open_interval_bound_seconds": bound, "host_boot": boot_iso}
    return runtimes, occupancy, occupancy_summary(intervals, since, until)
