"""Batched multi-root SQLite collection for session-time dashboards."""

from __future__ import annotations

import os
import sqlite3
from pathlib import Path

from session_time_common import path_matches
from session_time_db import (
    OBS_PLAN_QUERY,
    OBS_QUERY,
    SESSION_QUERY,
    append_observability,
    consume_session_record,
    escaped_like,
    finalized_sessions,
    note_scan,
    observability_interval,
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
        SELECT s.id, s.title, s.directory, m.time_created, m.data
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
