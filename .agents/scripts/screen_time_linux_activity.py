# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Persist sampled human input evidence as compact active intervals.

Each sample supplies the latest human-input epoch. Time counts as active from
an input until an idle cut-off later, only while the sampler proves the host
stayed awake. Completed intervals and sampler coverage spans are appended to
screen-activity.jsonl; the open interval lives in screen-activity-state.json.
Linux (tty/desktop idle) and macOS (HIDIdleTime) samplers share this store and
differ only in the collector name, so both platforms apply the same rule.
"""

from __future__ import annotations

import datetime as dt
import fcntl
import json
import os
import tempfile
from pathlib import Path

from screen_time_interval_common import DAY, WINDOWS, completed_day_window, local_date, local_midnight_epoch, safe_float, union_intervals

COLLECTOR = "linux-input-activity"
LOG_NAME = "screen-activity.jsonl"
STATE_NAME = "screen-activity-state.json"
LOCK_NAME = ".screen-activity.lock"
DEFAULT_IDLE_SECONDS = 300
MIN_SAMPLE_GAP = 180
RETENTION_SECONDS = 400 * DAY
STALE_HOURS = 72
# Evidence kinds meaning a human input source existed but could not be read.
PARTIAL_EVIDENCE = ("graphical-idle-unavailable", "hid-idle-unavailable")


def idle_seconds():
    value = safe_float(os.environ.get("AIDEVOPS_SCREEN_ACTIVITY_IDLE_SECONDS"))
    return int(value) if value is not None and 60 <= value <= 3600 else DEFAULT_IDLE_SECONDS


def source_name(idle, collector=COLLECTOR):
    return f"{collector}:idle-cutoff-{idle}s"


def pair(value):
    if not isinstance(value, (list, tuple)) or len(value) != 2:
        return None
    left, right = safe_float(value[0]), safe_float(value[1])
    return [left, right] if left is not None and right is not None and right >= left else None


def normalized_state(payload):
    payload = payload if isinstance(payload, dict) else {}
    evidence = payload.get("evidence")
    return {
        "open": pair(payload.get("open")),
        "coverage": pair(payload.get("coverage")),
        "last_input": safe_float(payload.get("last_input")),
        "last_sample": safe_float(payload.get("last_sample")),
        "evidence": [str(item) for item in evidence] if isinstance(evidence, list) else [],
        "idle_seconds": safe_float(payload.get("idle_seconds")),
    }


def close_open(state):
    span, state["open"] = state["open"], None
    return [("active", span)] if span and span[1] > span[0] else []


def advance_coverage(state, now, contiguous):
    span = state["coverage"]
    if span and contiguous:
        span[1] = now
        return []
    state["coverage"] = [now, now]
    return [("coverage", span)] if span and span[1] > span[0] else []


def accept_input(state, now, last_input, idle):
    previous = state["last_input"]
    if last_input is None or (previous is not None and last_input <= previous):
        return []
    last_input = state["last_input"] = min(last_input, now)
    # Never claim time before this coverage span proved the sampler was running.
    start = max(last_input, state["coverage"][0])
    end = max(start, min(last_input + idle, now))
    if state["open"] and start <= state["open"][1]:
        state["open"][1] = max(state["open"][1], end)
        return []
    done = close_open(state)
    state["open"] = [start, end]
    return done


def extend_open(state, now, idle):
    """Carry the open interval toward its idle cut-off; close it once reached."""
    if not state["open"] or state["last_input"] is None:
        return []
    cutoff = state["last_input"] + idle
    state["open"][1] = max(state["open"][1], min(cutoff, now))
    return close_open(state) if state["open"][1] >= cutoff else []


def advance(state, now, last_input, idle):
    """Apply one sample; return completed (kind, [start, end]) records."""
    previous = state["last_sample"]
    contiguous = previous is not None and 0 <= now - previous <= max(idle, MIN_SAMPLE_GAP)
    # After suspend, shutdown or sampler downtime the tail cannot cross the gap.
    done = extend_open(state, now, idle) if contiguous else close_open(state)
    done += advance_coverage(state, now, contiguous)
    done += accept_input(state, now, last_input, idle)
    done += extend_open(state, now, idle)
    state["last_sample"] = now
    return done


def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def parse_record(line):
    try:
        row = json.loads(line)
    except ValueError:
        return None
    if not isinstance(row, dict) or row.get("kind") not in ("active", "coverage"):
        return None
    span = pair([row.get("start"), row.get("end")])
    return (row["kind"], span[0], span[1]) if span else None


def read_records(log_path):
    try:
        lines = log_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    return [record for record in map(parse_record, lines) if record is not None]


def record_line(kind, left, right, collector=COLLECTOR):
    row = {"kind": kind, "start": round(left, 1), "end": round(right, 1), "collector": collector}
    return json.dumps(row, sort_keys=True) + "\n"


def write_atomic(path, text):
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(temporary, path)


def prune_records(log_path, cutoff, collector=COLLECTOR):
    records = read_records(log_path)
    keep = [record for record in records if record[2] >= cutoff]
    if len(keep) != len(records):
        write_atomic(log_path, "".join(record_line(*record, collector) for record in keep))


def persist(directory, state, done, prune_before, collector=COLLECTOR):
    log_path = directory / LOG_NAME
    if done:
        with log_path.open("a", encoding="utf-8") as handle:
            handle.writelines(record_line(kind, *span, collector) for kind, span in done)
    if prune_before is not None:
        prune_records(log_path, prune_before, collector)
    write_atomic(directory / STATE_NAME, json.dumps(state, sort_keys=True) + "\n")


def record_sample(directory, now, evidence, collector=COLLECTOR):
    """Advance the persisted state with one evidence sample under a lock."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / LOCK_NAME).open("a", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return {"status": "busy"}
        state = normalized_state(read_json(directory / STATE_NAME))
        # Prune once per local day rather than rewriting the log every minute.
        new_day = local_date(state["last_sample"]) != local_date(now)
        idle = idle_seconds()
        done = advance(state, now, safe_float(evidence.get("last_input")), idle)
        state.update(evidence=list(evidence.get("kinds", [])), idle_seconds=idle)
        persist(directory, state, done, now - RETENTION_SECONDS if new_day else None, collector)
    return {"status": "sampled", "last_input": state["last_input"], "open": state["open"], "evidence": state["evidence"]}


def day_markers(spans):
    """One epoch per local day a coverage span touched, so idle days read as 0h."""
    markers = []
    for left, right in spans:
        first, last = local_date(left), local_date(right)
        if first is None or last is None:
            continue
        days = range(1, min((last - first).days, 400) + 1)
        markers += [left] + [local_midnight_epoch(first + dt.timedelta(days=offset)) for offset in days]
    return [marker for marker in markers if marker is not None]


def stored_spans(directory, state, now):
    """Return unioned (active, coverage) spans in the trailing year."""
    records = read_records(directory / LOG_NAME)
    # Start at local midnight 365 days ago so the profile year's first day is whole.
    year_start = completed_day_window(now, 365)[0]
    window = (now - WINDOWS["year"] if year_start is None else min(year_start, now - WINDOWS["year"]), now)
    spans = {}
    for kind in ("active", "coverage"):
        current = state["open"] if kind == "active" else state["coverage"]
        spans[kind] = union_intervals([record[1:] for record in records if record[0] == kind] + [current], *window)
    return spans["active"], spans["coverage"]


def unavailable(reason, collector=COLLECTOR):
    return {"status": "unavailable", "source": collector, "reason": reason, "intervals": []}


def collection_status(state, freshness):
    if freshness > STALE_HOURS:
        return "stale"
    return "partial" if any(kind in PARTIAL_EVIDENCE for kind in state["evidence"]) else "ok"


def activity_collection(directory, now, collector=COLLECTOR):
    if directory is None:
        return unavailable("activity-directory-unset", collector)
    directory = Path(directory)
    state = normalized_state(read_json(directory / STATE_NAME))
    active, coverage = stored_spans(directory, state, now)
    latest = state["last_sample"] or (coverage[-1][1] if coverage else None)
    if latest is None:
        return unavailable("no-input-activity-samples", collector)
    freshness = max(0.0, (now - latest) / 3600)
    earliest = coverage[0][0] if coverage else latest
    markers = day_markers(coverage)
    return {
        "status": collection_status(state, freshness),
        "source": source_name(int(state["idle_seconds"] or idle_seconds()), collector),
        "reason": "sampled-input-activity",
        "intervals": active,
        "observations": len(markers),
        "latest_epoch": latest,
        "earliest_epoch": earliest,
        "freshness_hours": round(freshness, 1),
        "observation_epochs": markers,
        "coverage_start_epoch": earliest,
        "coverage_end_epoch": latest,
        # Before the first sample nothing was measured: periods ending earlier are
        # unknown, not zero. Later sampler gaps mean the host was off or asleep.
        "observed_since_epoch": earliest,
        "evidence": state["evidence"],
    }
