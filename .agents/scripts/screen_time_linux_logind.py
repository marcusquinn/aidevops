"""Parse systemd-logind session, lock, and lid state observations."""

from __future__ import annotations

import os
import re
import sys

from screen_time_interval_common import WINDOWS, parse_timestamp, union_intervals

SESSION_NEW = re.compile(r"New session ([A-Za-z0-9_.-]+) of user ([^ .]+)", re.I)
SESSION_END = re.compile(r"(?:Removed session|Session) ([A-Za-z0-9_.-]+)(?: logged out)?", re.I)
SESSION_ID = re.compile(r"Session ([A-Za-z0-9_.-]+)", re.I)


def is_active(context):
    state = context["state"]
    return state["lid_open"] and any(not locked for locked in state["sessions"].values())


def session_message_ids(message):
    lowered = message.lower()
    lock_match = SESSION_ID.search(message) if "locked" in lowered else None
    end_match = SESSION_END.search(message)
    lock_id = lock_match.group(1).rstrip(".") if lock_match else ""
    end_id = end_match.group(1).rstrip(".") if end_match else ""
    return lowered, lock_id, end_id


def apply_message(context, message, user):
    state = context["state"]
    new_match = SESSION_NEW.search(message)
    lowered, lock_id, end_id = session_message_ids(message)
    recognized = True
    if new_match and new_match.group(2) == user:
        state["sessions"][new_match.group(1).rstrip(".")] = False
    elif "Lid closed" in message:
        state["lid_open"] = False
    elif "Lid opened" in message:
        state["lid_open"] = True
    elif lock_id in state["sessions"]:
        state["sessions"][lock_id] = "unlocked" not in lowered
    elif end_id in state["sessions"]:
        state["sessions"].pop(end_id, None)
    else:
        recognized = False
    return recognized


def parse_line(line, now):
    parts = line.split(None, 1)
    timestamp = parse_timestamp(parts[0]) if len(parts) == 2 else None
    if timestamp is None or timestamp > now:
        return None
    return timestamp, parts[1]


def debug_event(context, event, before, after):
    if os.environ.get("AIDEVOPS_SCREEN_TIME_DEBUG") != "1":
        return
    timestamp, message = event
    state = context["state"]
    print(
        f"screen-time event ts={timestamp} before={before} after={after} "
        f"sessions={state['sessions']} lid_open={state['lid_open']} message={message}",
        file=sys.stderr,
    )


def apply_event(context, event, user):
    before = is_active(context)
    if not apply_message(context, event[1], user):
        return False
    after = is_active(context)
    debug_event(context, event, before, after)
    if before and not after and context["opened"] is not None:
        context["intervals"].append((context["opened"], event[0]))
    if before != after:
        context["opened"] = event[0] if after else None
    context["active"] = after
    return True


def collect_linux_events(lines, now, user):
    context = {"state": {"sessions": {}, "lid_open": True}, "intervals": [], "opened": None, "active": False}
    observations = []
    for line in lines:
        event = parse_line(line, now)
        if event is not None and apply_event(context, event, user):
            observations.append(event[0])
    if context["active"] and context["opened"] is not None:
        context["intervals"].append((context["opened"], now))
    intervals = union_intervals(context["intervals"], now - WINDOWS["year"], now)
    return intervals, observations


def linux_payload(intervals, observations, now):
    latest = max(observations)
    freshness = max(0.0, (now - latest) / 3600)
    return {
        "status": "stale" if freshness > 72 else "ok",
        "source": "linux-systemd-logind:session-lid-lock-state",
        "reason": "source-observations",
        "intervals": intervals,
        "observations": len(observations),
        "latest_epoch": latest,
        "earliest_epoch": min(observations),
        "freshness_hours": round(freshness, 1),
        "observation_epochs": observations,
        "coverage_start_epoch": min(observations),
        "coverage_end_epoch": latest,
    }
