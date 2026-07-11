"""Read-only SQLite collection for session and observability intervals."""

from __future__ import annotations

import datetime as dt
import glob
import json
import os
import sqlite3
from pathlib import Path

from session_time_common import path_matches, safe_int

SESSION_QUERY = """
    SELECT s.id, s.title, s.directory, m.time_created, m.data
    FROM session s JOIN message m ON m.session_id=s.id
    WHERE s.parent_id IS NULL AND m.time_created >= ?
    ORDER BY s.id, m.time_created
"""
OBS_QUERY = """
    SELECT timestamp, session_id, duration_ms, project_path FROM llm_requests
    WHERE timestamp >= ? AND duration_ms > 0
      AND typeof(duration_ms) IN ('integer','real')
      AND session_id IS NOT NULL AND session_id != ''
"""
OBS_ROOT_QUERY = """
    SELECT timestamp, session_id, duration_ms, project_path FROM llm_requests
    WHERE timestamp >= ? AND duration_ms > 0
      AND typeof(duration_ms) IN ('integer','real')
      AND session_id IS NOT NULL AND session_id != ''
      AND (project_path = ? OR project_path LIKE ? ESCAPE '\\'
           OR project_path LIKE ? ESCAPE '\\' OR project_path LIKE ? ESCAPE '\\')
"""
OBS_PLAN_QUERY = """
    EXPLAIN QUERY PLAN
    SELECT timestamp, session_id, duration_ms, project_path FROM llm_requests
    WHERE timestamp >= ? AND duration_ms > 0
      AND typeof(duration_ms) IN ('integer','real')
      AND session_id IS NOT NULL AND session_id != ''
"""
OBS_ROOT_PLAN_QUERY = """
    EXPLAIN QUERY PLAN
    SELECT timestamp, session_id, duration_ms, project_path FROM llm_requests
    WHERE timestamp >= ? AND duration_ms > 0
      AND typeof(duration_ms) IN ('integer','real')
      AND session_id IS NOT NULL AND session_id != ''
      AND (project_path = ? OR project_path LIKE ? ESCAPE '\\'
           OR project_path LIKE ? ESCAPE '\\' OR project_path LIKE ? ESCAPE '\\')
"""


def readonly_connection(db_path):
    uri = db_path.resolve().as_uri() + "?mode=ro"
    return sqlite3.connect(uri, uri=True, timeout=5)


def db_paths(home, explicit):
    if explicit:
        path = Path(explicit)
        return [path] if path.is_file() else []
    paths = [home / ".local/share/opencode/opencode.db", home / ".local/share/opencode/opencode-archive.db"]
    work = Path(os.environ.get("AIDEVOPS_WORK_DIR", home / ".aidevops/.agent-workspace/work"))
    paths.extend(Path(item) for item in glob.glob(str(work / "opencode-interactive/*/opencode/opencode.db")))
    return [item for item in paths if item.is_file()]


def note_scan(db_path):
    counter = os.environ.get("AIDEVOPS_SESSION_SCAN_COUNTER")
    if counter:
        with open(counter, "a", encoding="utf-8") as handle:
            handle.write(str(db_path) + "\n")


def parse_message(data):
    try:
        payload = json.loads(data or "{}")
    except (json.JSONDecodeError, TypeError, ValueError):
        return None
    if not isinstance(payload, dict) or not isinstance(payload.get("time", {}), dict):
        return None
    return payload.get("role"), safe_int(payload.get("time", {}).get("completed"))


def session_row(sessions, values):
    session_id, title, directory, created = values
    return sessions.setdefault(session_id, {
        "session_id": session_id,
        "title": title or "",
        "directory": directory or "",
        "human": [],
        "machine": [],
        "first": created,
        "last": created,
        "previous_role": None,
        "previous_completed": None,
    })


def apply_message(row, role, created, completed):
    previous = row["previous_completed"]
    if role == "user" and row["previous_role"] == "assistant" and previous:
        gap = created - previous
        if 0 < gap <= 3600000:
            row["human"].append((previous, created))
    if role == "assistant" and completed and completed > created:
        row["machine"].append((created, completed))
    row.update(previous_role=role, previous_completed=completed)
    row["first"] = min(row["first"], created)
    row["last"] = max(row["last"], completed or created)


def consume_session_record(sessions, record, root):
    session_id, title, directory, raw_created, data = record
    created = safe_int(raw_created)
    parsed = parse_message(data)
    if not path_matches(directory, root) or not session_id or created is None or parsed is None:
        return 1 if path_matches(directory, root) else 0
    row = session_row(sessions, (session_id, title, directory, created))
    apply_message(row, parsed[0], created, parsed[1])
    return 0


def finalized_sessions(sessions):
    for row in sessions.values():
        row.pop("previous_role", None)
        row.pop("previous_completed", None)
    return list(sessions.values())


def query_session_db(db_path, root, since):
    note_scan(db_path)
    sessions = {}
    skipped = 0
    try:
        with readonly_connection(db_path) as connection:
            for record in connection.execute(SESSION_QUERY, (since,)):
                skipped += consume_session_record(sessions, record, root)
    except (OSError, sqlite3.Error):
        return [], False, skipped
    return finalized_sessions(sessions), True, skipped


def parse_iso_ms(value):
    try:
        parsed = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return int(parsed.timestamp() * 1000)
    except (OSError, ValueError, TypeError, OverflowError):
        return None


def safe_cutoff(since):
    try:
        seconds = float(since) / 1000
        seconds = min(253402300799.0, max(0.0, seconds))
        parsed = dt.datetime.fromtimestamp(seconds, dt.timezone.utc)
    except (OSError, OverflowError, TypeError, ValueError):
        parsed = dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc)
    return parsed.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def escaped_like(value):
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def observability_query(root, cutoff):
    if not root:
        return OBS_QUERY, OBS_PLAN_QUERY, (cutoff,)
    escaped = escaped_like(root)
    params = (cutoff, root, f"{escaped}/%", f"{escaped}.%", f"{escaped}-%")
    return OBS_ROOT_QUERY, OBS_ROOT_PLAN_QUERY, params


def write_query_plan(connection, query, params):
    plan_file = os.environ.get("AIDEVOPS_OBS_QUERY_PLAN_FILE")
    if not plan_file:
        return
    plan = connection.execute(query, params).fetchall()
    Path(plan_file).write_text("\n".join(str(row[3]) for row in plan) + "\n", encoding="utf-8")


def observability_interval(record, since, now):
    timestamp, session_id, duration_ms, project_path = record
    end = parse_iso_ms(timestamp)
    duration = safe_int(duration_ms)
    if end is None or duration is None or end < since:
        return None
    end = min(now, end)
    start = max(since, end - duration)
    if end <= start:
        return None
    return session_id, project_path, start, end


def append_observability(rows, interval):
    session_id, project_path, start, end = interval
    row = rows.setdefault(session_id, {"intervals": [], "directory": project_path or ""})
    row["intervals"].append((start, end))


def write_selected_count(selected):
    counter = os.environ.get("AIDEVOPS_OBS_ROW_COUNTER")
    if counter:
        with open(counter, "a", encoding="utf-8") as handle:
            handle.write(f"{selected}\n")


def query_observability(home, root, since, now):
    db_path = Path(os.environ.get("AIDEVOPS_OBS_DB_FILE", home / ".aidevops/.agent-workspace/observability/llm-requests.db"))
    if not db_path.is_file():
        return {}, False, 0
    rows, skipped, selected = {}, 0, 0
    query, plan_query, params = observability_query(root, safe_cutoff(since))
    try:
        with readonly_connection(db_path) as connection:
            write_query_plan(connection, plan_query, params)
            for record in connection.execute(query, params):
                selected += 1
                interval = observability_interval(record, since, now)
                if interval is None:
                    skipped += 1
                else:
                    append_observability(rows, interval)
        write_selected_count(selected)
    except (OSError, sqlite3.Error):
        return {}, False, skipped
    return rows, True, skipped
