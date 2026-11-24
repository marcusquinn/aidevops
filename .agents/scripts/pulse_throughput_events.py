"""Streaming lifecycle, refill and supervisor events from pulse.log."""
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

from collections import Counter
import math
import re

from pulse_throughput_logs import iso_time, lines

ISO_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})")
FIELD_RE = re.compile(r"\b([a-z_]+)=([^\s,)]+)")


def record_time(fields, line, success):
    if success:
        return float(fields["epoch"])
    if "ts" in fields:
        return iso_time(fields["ts"])
    match = ISO_RE.search(line)
    return iso_time(match.group()) if match else None


def pulse_records(log_dir):
    """Retain only one timestamp of context for untimestamped round caps."""
    context_timestamp = None
    for line in lines(log_dir / "pulse.log"):
        fields = dict(FIELD_RE.findall(line))
        success = "LLM supervisor completed successfully" in line
        try:
            timestamp = record_time(fields, line, success)
        except (ValueError, OverflowError, KeyError):
            continue
        if timestamp is None and "max_parallel" in fields:
            timestamp = context_timestamp
        if timestamp is None or not math.isfinite(timestamp):
            continue
        context_timestamp = timestamp
        yield timestamp, fields, line, success


def positive_cap(fields):
    try:
        value = int(fields.get("max_parallel", ""))
        return value if value > 0 else None
    except ValueError:
        return None


def refill_metrics(refills, available):
    if not available:
        return {"trigger_recorded": None, "outcomes_by_source": None}
    return {
        "trigger_recorded": sum(count for (_, action, _), count in refills.items()
                                if action == "trigger_recorded"),
        "outcomes_by_source": [
            {"source": source, "action": action, "reason": reason or None, "count": count}
            for (source, action, reason), count in sorted(refills.items())],
    }


def pulse_metrics(log_dir, since, until):
    refills = Counter()
    supervisor = set()
    pulse_seen = False
    cap_observations = []
    exits = []
    for timestamp, fields, line, success in pulse_records(log_dir):
        in_window = since <= timestamp < until
        pulse_seen |= in_window
        if success and timestamp < until:
            supervisor.add(timestamp)
        if in_window and "[pulse-event-refill]" in line:
            action = fields.get("action", "unknown")
            refills[(fields.get("source", "unknown"), action, fields.get("reason", ""))] += 1
        cap = positive_cap(fields)
        if timestamp < until and cap is not None:
            cap_observations.append((timestamp, cap))
        # Exits after until allow pairing intervals across the right boundary.
        if "[lifecycle] worker_exited" in line and since <= timestamp < until + 21600:
            exits.append((timestamp, fields.get("issue", "")))
    return exits, cap_observations, supervisor, pulse_seen, refill_metrics(refills, pulse_seen)
