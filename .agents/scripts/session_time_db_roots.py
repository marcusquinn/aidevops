"""Batched multi-root SQLite collection for session-time dashboards."""

from __future__ import annotations

import copy
import json
import os
import sqlite3
import tempfile
import time
from pathlib import Path

from session_time_common import path_matches, safe_int
from session_time_db import (
    MESSAGE_FIELDS,
    OBS_PLAN_QUERY,
    OBS_QUERY,
    SESSION_QUERY,
    append_observability,
    consume_session_record,
    db_paths,
    escaped_like,
    finalized_sessions,
    note_scan,
    observability_interval,
    parse_iso_ms,
    readonly_connection,
    safe_cutoff,
    write_query_plan,
    write_selected_count,
)


def root_filter(column, roots):
    clauses = []
    params = []
    for root in roots:
        escaped = escaped_like(root)
        clauses.append(
            f"({column} = ? OR {column} LIKE ? ESCAPE '\\' "
            f"OR {column} LIKE ? ESCAPE '\\' OR {column} LIKE ? ESCAPE '\\')"
        )
        params.extend((root, f"{escaped}/%", f"{escaped}.%", f"{escaped}-%"))
    return " OR ".join(clauses), params


def session_query(roots, since):
    if not roots:
        return SESSION_QUERY, (since,)
    predicate, root_params = root_filter("s.directory", roots)
    query = f"""
        SELECT s.id, s.title, s.directory, m.time_created, {MESSAGE_FIELDS}
        FROM session s JOIN message m ON m.session_id=s.id
        WHERE s.parent_id IS NULL AND m.time_created >= ?
          AND ({predicate})
        ORDER BY s.id, m.time_created
    """
    return query, (since, *root_params)


def query_session_db_roots(db_path, roots, since):
    note_scan(db_path)
    roots = roots or [""]
    sessions = {root: {} for root in roots}
    skipped = {root: 0 for root in roots}
    query, params = session_query([] if roots == [""] else roots, since)
    try:
        with readonly_connection(db_path) as connection:
            for record in connection.execute(query, params):
                for root in roots:
                    if path_matches(record[2], root):
                        skipped[root] += consume_session_record(sessions[root], record, root)
    except (OSError, sqlite3.Error):
        return {root: [] for root in roots}, False, skipped
    return {root: finalized_sessions(sessions[root]) for root in roots}, True, skipped


def observability_query_roots(roots, cutoff):
    if not roots:
        return OBS_QUERY, OBS_PLAN_QUERY, (cutoff,)
    predicate, root_params = root_filter("project_path", roots)
    query = f"""
        SELECT timestamp, session_id, duration_ms, project_path FROM llm_requests
        WHERE timestamp >= ? AND duration_ms > 0
          AND typeof(duration_ms) IN ('integer','real')
          AND session_id IS NOT NULL AND session_id != ''
          AND ({predicate})
    """
    return query, "EXPLAIN QUERY PLAN " + query, (cutoff, *root_params)


def query_observability_roots(home, roots, since, now):
    roots = roots or [""]
    db_path = Path(os.environ.get("AIDEVOPS_OBS_DB_FILE", home / ".aidevops/.agent-workspace/observability/llm-requests.db"))
    if not db_path.is_file():
        return {root: {} for root in roots}, False, {root: 0 for root in roots}
    rows = {root: {} for root in roots}
    skipped = {root: 0 for root in roots}
    selected = 0
    query, plan_query, params = observability_query_roots([] if roots == [""] else roots, safe_cutoff(since))
    try:
        with readonly_connection(db_path) as connection:
            write_query_plan(connection, plan_query, params)
            for record in connection.execute(query, params):
                selected += 1
                interval = observability_interval(record, since, now)
                for root in roots:
                    if not path_matches(record[3], root):
                        continue
                    if interval is None:
                        skipped[root] += 1
                    else:
                        append_observability(rows[root], interval)
        write_selected_count(selected)
    except (OSError, sqlite3.Error):
        return {root: {} for root in roots}, False, skipped
    return rows, True, skipped


# --- Incremental all-directories collection (t19433, GH#40628) ---------------
# The hourly profile routine re-read a year of every source DB on each run and
# was starved under Background I/O (70+ min). This keeps a derived state file:
# a rowid watermark per source DB, the per-session interval state at that
# watermark, and immutable archive segments summarised once (size + mtime).
# Each run reads only rows past the watermark, in short rowid-chunked read-only
# transactions bounded by a time budget, so a first build resumes across runs.
# Message rows are re-read until they are SETTLE_MS old because assistant
# `time.completed` is written after the row is inserted.

STATE_VERSION = 1
SETTLE_MS = 2 * 3600 * 1000
SESSION_CHUNK_ROWS = 50000
OBS_CHUNK_ROWS = 200000
INTERNAL_KEYS = ("previous_role", "previous_completed")
INC_SESSION_QUERY = f"""
    SELECT s.id, s.title, s.directory, m.time_created, {MESSAGE_FIELDS}, m.rowid
    FROM session s JOIN message m ON m.session_id=s.id
    WHERE s.parent_id IS NULL AND m.rowid > ? AND m.rowid <= ? AND m.time_created >= ?
    ORDER BY s.id, m.time_created
"""
# `+timestamp` keeps the planner on the rowid range instead of a year-wide
# timestamp index scan.
INC_OBS_QUERY = """
    SELECT timestamp, session_id, duration_ms, project_path, rowid FROM llm_requests
    WHERE rowid > ? AND rowid <= ? AND +timestamp >= ? AND duration_ms > 0
      AND typeof(duration_ms) IN ('integer','real')
      AND session_id IS NOT NULL AND session_id != ''
"""


def empty_state():
    return {"version": STATE_VERSION, "sessions": {}, "obs": {}}


def load_state(path):
    try:
        loaded = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return empty_state()
    if not isinstance(loaded, dict) or loaded.get("version") != STATE_VERSION:
        return empty_state()
    loaded.setdefault("sessions", {})
    loaded.setdefault("obs", {})
    return loaded


def save_state(path, state):
    target = Path(path)
    if target.is_symlink() or not target.parent.is_dir():
        raise OSError("session-time state path is not a safe regular-file target")
    handle, temporary = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
    try:
        os.fchmod(handle, 0o600)
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(state, stream, separators=(",", ":"))
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def file_identity(db_path):
    stat = db_path.stat()
    return [stat.st_size, stat.st_mtime_ns]


def prune_session_entry(entry, floor):
    kept = {}
    for session_id, row in entry.get("sessions", {}).items():
        if row.get("last", 0) < floor:
            continue
        row["human"] = [item for item in row["human"] if item[1] >= floor]
        row["machine"] = [item for item in row["machine"] if item[1] >= floor]
        kept[session_id] = row
    entry["sessions"] = kept


def public_rows(sessions):
    return [{k: v for k, v in row.items() if k not in INTERNAL_KEYS} for row in sessions.values()]


def settled_boundary(rows, high, now):
    """Highest rowid whose row (and every earlier row) is old enough to fold."""
    cutoff = now - SETTLE_MS
    for record in sorted(rows, key=lambda item: item[-1]):
        created = safe_int(record[3])
        if created is None or created >= cutoff:
            return record[-1] - 1
    return high


def scan_session_source(db_path, entry, since, now, deadline, checkpoint):
    """Advance one source entry; return (public rows, ok, complete)."""
    note_scan(db_path)
    pending = []
    try:
        with readonly_connection(db_path) as connection:
            top = connection.execute("SELECT max(rowid) FROM message").fetchone()[0] or 0
            if top < entry["rowid"]:
                entry.update(rowid=0, sessions={}, skipped=0)
            while entry["rowid"] < top:
                if time.monotonic() > deadline:
                    return public_rows(entry["sessions"]), True, False
                low = entry["rowid"]
                high = min(top, low + SESSION_CHUNK_ROWS)
                rows = [tuple(item) for item in connection.execute(INC_SESSION_QUERY, (low, high, since))]
                boundary = high if high < top else settled_boundary(rows, high, now)
                for record in rows:
                    if record[-1] <= boundary:
                        entry["skipped"] += consume_session_record(entry["sessions"], record[:7], "")
                entry["rowid"] = max(low, boundary)
                pending = [record for record in rows if record[-1] > boundary]
                checkpoint()
                if pending or boundary <= low:
                    break
    except (OSError, sqlite3.Error):
        return [], False, False
    touched = {record[0] for record in pending}
    working = {sid: copy.deepcopy(row) for sid, row in entry["sessions"].items() if sid in touched}
    for record in pending:
        consume_session_record(working, record[:7], "")
    merged = dict(entry["sessions"])
    merged.update(working)
    return public_rows(merged), True, True


def collect_sessions_incremental(home, explicit, state, since, now, deadline, checkpoint):
    paths = db_paths(home, explicit)
    keys = {str(path) for path in paths}
    state["sessions"] = {key: value for key, value in state["sessions"].items() if key in keys}
    sessions, seen, ok, complete, skipped = [], set(), False, True, 0
    for path in paths:
        key = str(path)
        identity = file_identity(path)
        entry = state["sessions"].get(key)
        archive = path.name.startswith("opencode-archive")
        if entry is None or (archive and entry.get("identity") != identity):
            entry = {"rowid": 0, "sessions": {}, "skipped": 0, "complete": False}
        prune_session_entry(entry, since)
        state["sessions"][key] = entry
        if archive and entry.get("complete") and entry.get("identity") == identity:
            rows, source_ok, source_done = public_rows(entry["sessions"]), True, True
        else:
            rows, source_ok, source_done = scan_session_source(path, entry, since, now, deadline, checkpoint)
            if archive and source_ok and source_done:
                entry["complete"], entry["identity"] = True, identity
        ok = ok or source_ok
        complete = complete and (source_done or not source_ok)
        skipped += entry["skipped"]
        for row in rows:
            if row["session_id"] not in seen:
                sessions.append(row)
                seen.add(row["session_id"])
    return sessions, ok, complete, skipped


def scan_obs_source(db_path, entry, deadline, checkpoint):
    try:
        with readonly_connection(db_path) as connection:
            top = connection.execute("SELECT max(rowid) FROM llm_requests").fetchone()[0] or 0
            if top < entry["rowid"]:
                entry.update(rowid=0, rows={}, skipped=0)
            while entry["rowid"] < top:
                if time.monotonic() > deadline:
                    return True, False
                low = entry["rowid"]
                high = min(top, low + OBS_CHUNK_ROWS)
                query = connection.execute(INC_OBS_QUERY, (low, high, entry["cutoff"]))
                for timestamp, session_id, duration_ms, project_path, _ in query:
                    end, duration = parse_iso_ms(timestamp), safe_int(duration_ms)
                    if end is None or duration is None:
                        entry["skipped"] += 1
                        continue
                    row = entry["rows"].setdefault(session_id, {"intervals": [], "directory": project_path or ""})
                    row["intervals"].append([end - duration, end])
                entry["rowid"] = high
                checkpoint()
    except (OSError, sqlite3.Error):
        return False, False
    return True, True


def clipped_obs_rows(rows, since, now):
    result = {}
    for session_id, row in rows.items():
        intervals = []
        for start, end in row["intervals"]:
            if end < since:
                continue
            end = min(now, end)
            start = max(since, start)
            if end > start:
                intervals.append((start, end))
        if intervals:
            result[session_id] = {"intervals": intervals, "directory": row["directory"]}
    return result


def collect_observability_incremental(home, state, since, now, deadline, checkpoint):
    default = home / ".aidevops/.agent-workspace/observability/llm-requests.db"
    db_path = Path(os.environ.get("AIDEVOPS_OBS_DB_FILE", default))
    if not db_path.is_file():
        return {}, False, True, 0
    key = str(db_path)
    entry = state["obs"].get(key) or {"rowid": 0, "rows": {}, "skipped": 0}
    for session_id in list(entry["rows"]):
        row = entry["rows"][session_id]
        row["intervals"] = [item for item in row["intervals"] if item[1] >= since]
        if not row["intervals"]:
            del entry["rows"][session_id]
    entry["cutoff"] = safe_cutoff(since)
    state["obs"] = {key: entry}
    ok, complete = scan_obs_source(db_path, entry, deadline, checkpoint)
    if not ok:
        return {}, False, False, entry["skipped"]
    return clipped_obs_rows(entry["rows"], since, now), True, complete, entry["skipped"]
