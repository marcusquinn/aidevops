"""Statistics and endpoint-sweep sampling for local Pulse reports."""
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

from bisect import bisect_right
import math
import statistics


def summary(values, available=True):
    if not values:
        return {"count": 0 if available else None, "median": None, "p90": None}
    ordered = sorted(values)
    return {"count": len(values), "median": statistics.median(ordered),
            "p90": ordered[max(0, math.ceil(len(ordered) * 0.9) - 1)]}


def sample_intervals(intervals, since, until, step):
    """Sweep endpoints instead of testing every interval at every sample."""
    starts = sorted(start for start, _ in intervals)
    ends = sorted(end for _, end in intervals)
    for index in range(math.ceil((until - since) / step)):
        point = since + index * step
        yield bisect_right(starts, point) - bisect_right(ends, point)


def concurrency_metrics(ceremonies, timing_seen, cap_observations, since, until):
    concurrency = list(sample_intervals(ceremonies, since, until, 10)) if timing_seen or ceremonies else []
    running = [value for value in concurrency if value > 0]
    caps = {cap for _, cap in cap_observations}
    cap_observations.sort()
    cap_times = [timestamp for timestamp, _ in cap_observations]
    capped_samples = []
    for index, value in enumerate(concurrency):
        observation = bisect_right(cap_times, since + index * 10) - 1
        if observation >= 0:
            capped_samples.append(value >= cap_observations[observation][1])
    return {
        "sample_seconds": 10,
        "idle_share": concurrency.count(0) / len(concurrency) if concurrency else None,
        "mean_while_running": statistics.mean(running) if running else None,
        "observed_cap": next(iter(caps)) if len(caps) == 1 else None,
        "observed_caps": sorted(caps) if caps else None,
        "cap_sample_coverage_share": len(capped_samples) / len(concurrency) if concurrency else None,
        "share_at_cap": statistics.mean(capped_samples) if capped_samples else None,
    }


def census_metrics(observations, since, until, step=300, max_age=600):
    """Carry each round's ps census of live workers forward, at most max_age."""
    # Timestamp only: equal-time rounds keep log order and a None target never compares.
    observations.sort(key=lambda observation: observation[0])
    times = [timestamp for timestamp, _, _ in observations]
    points = math.ceil((until - since) / step)
    workers, targets = [], []
    for index in range(points):
        point = since + index * step
        latest = bisect_right(times, point) - 1
        if latest < 0 or point - times[latest] > max_age:
            continue
        _, active, target = observations[latest]
        workers.append(active)
        if target is not None:
            targets.append(target)
    return {
        "sample_seconds": step, "max_age_seconds": max_age,
        "observations": sum(since <= timestamp < until for timestamp in times),
        "coverage_share": len(workers) / points if points else None,
        "mean": statistics.mean(workers) if workers else None,
        "max": max(workers) if workers else None,
        "target_final_mean": statistics.mean(targets) if targets else None,
        "target_final_min": min(targets) if targets else None,
    }


def supervisor_metrics(supervisor, pulse_seen, since, until, now):
    successes = sorted(value for value in supervisor if since <= value < until)
    gaps = [(right - left) / 3600 for left, right in zip(successes, successes[1:])]
    return {
        "count": len(successes) if pulse_seen or successes else None,
        "gap_median_hours": statistics.median(gaps) if gaps else None,
        "gap_max_hours": max(gaps) if gaps else None,
        "hours_since_last_success": (now - max(supervisor)) / 3600 if supervisor else None,
    }
