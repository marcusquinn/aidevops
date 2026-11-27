"""Incremental observability (llm_requests) collection for the profile run.

t19433 / GH#40628. Rows are append-only, so a rowid watermark is enough: each
run reads only rows past it, in chunked read-only transactions bounded by the
scan deadline. Intervals are stored unclipped and clipped on every load.
"""

from __future__ import annotations

import os
import sqlite3
from pathlib import Path

from session_time_common import safe_int
from session_time_db import parse_iso_ms, readonly_connection, safe_cutoff

OBS_CHUNK_ROWS = 200000
# `+timestamp` keeps the planner on the rowid range instead of a year-wide
# timestamp index scan.
INC_OBS_QUERY = """
    SELECT timestamp, session_id, duration_ms, project_path, rowid FROM llm_requests
    WHERE rowid > ? AND rowid <= ? AND +timestamp >= ? AND duration_ms > 0
      AND typeof(duration_ms) IN ('integer','real')
      AND session_id IS NOT NULL AND session_id != ''
"""


def fold_obs_record(entry, record):
    timestamp, session_id, duration_ms, project_path, _ = record
    end, duration = parse_iso_ms(timestamp), safe_int(duration_ms)
    if end is None or duration is None:
        entry["skipped"] += 1
        return
    row = entry["rows"].setdefault(session_id, {"intervals": [], "directory": project_path or ""})
    row["intervals"].append([end - duration, end])


def scan_obs_source(db_path, entry, scan):
    try:
        with readonly_connection(db_path) as connection:
            top = connection.execute("SELECT max(rowid) FROM llm_requests").fetchone()[0] or 0
            if top < entry["rowid"]:
                entry.update(rowid=0, rows={}, skipped=0)
            while entry["rowid"] < top:
                if scan.expired():
                    return True, False
                low = entry["rowid"]
                high = min(top, low + OBS_CHUNK_ROWS)
                for record in connection.execute(INC_OBS_QUERY, (low, high, entry["cutoff"])):
                    fold_obs_record(entry, record)
                entry["rowid"] = high
                scan.checkpoint()
    except (OSError, sqlite3.Error):
        return False, False
    return True, True


def clipped_obs_rows(rows, scan):
    result = {}
    for session_id, row in rows.items():
        intervals = []
        for start, end in row["intervals"]:
            if end < scan.since:
                continue
            end = min(scan.now, end)
            start = max(scan.since, start)
            if end > start:
                intervals.append((start, end))
        if intervals:
            result[session_id] = {"intervals": intervals, "directory": row["directory"]}
    return result


def prune_obs_entry(entry, floor):
    for session_id in list(entry["rows"]):
        row = entry["rows"][session_id]
        row["intervals"] = [item for item in row["intervals"] if item[1] >= floor]
        if not row["intervals"]:
            del entry["rows"][session_id]


def collect_observability_incremental(home, state, scan):
    default = home / ".aidevops/.agent-workspace/observability/llm-requests.db"
    db_path = Path(os.environ.get("AIDEVOPS_OBS_DB_FILE", default))
    if not db_path.is_file():
        return {}, False, True, 0
    key = str(db_path)
    entry = state["obs"].get(key) or {"rowid": 0, "rows": {}, "skipped": 0}
    prune_obs_entry(entry, scan.since)
    entry["cutoff"] = safe_cutoff(scan.since)
    state["obs"] = {key: entry}
    ok, complete = scan_obs_source(db_path, entry, scan)
    if not ok:
        return {}, False, False, entry["skipped"]
    return clipped_obs_rows(entry["rows"], scan), True, complete, entry["skipped"]
