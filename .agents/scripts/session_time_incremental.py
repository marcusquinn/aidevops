"""Incremental all-directories collection for the profile session-time step.

t19433 / GH#40628. The hourly profile routine re-read a year of every source DB
on each run and was starved under Background I/O (70+ min). This keeps a
derived state file: a rowid watermark per source DB, the per-session interval
state at that watermark, and immutable archive segments summarised once
(keyed by size + mtime). Each run reads only rows past the watermark, in short
rowid-chunked read-only transactions bounded by a time budget, so a first
build resumes across runs. Message rows are re-read until they are SETTLE_MS
old because assistant `time.completed` is written after the row is inserted.
"""

from __future__ import annotations

import copy
import os
import sqlite3
import time

from session_time_common import safe_int
from session_time_db import (
    MESSAGE_FIELDS,
    consume_session_record,
    db_paths,
    note_scan,
    readonly_connection,
)
from session_time_incremental_obs import collect_observability_incremental
from session_time_state import Scan, file_identity, load_state, save_state

SETTLE_MS = 2 * 3600 * 1000
SESSION_CHUNK_ROWS = 50000
INTERNAL_KEYS = ("previous_role", "previous_completed")
# MESSAGE_FIELDS is a module constant; every value is bound as a parameter.
INC_SESSION_QUERY = f"""
    SELECT s.id, s.title, s.directory, m.time_created, {MESSAGE_FIELDS}, m.rowid
    FROM session s JOIN message m ON m.session_id=s.id
    WHERE s.parent_id IS NULL AND m.rowid > ? AND m.rowid <= ? AND m.time_created >= ?
    ORDER BY s.id, m.time_created
"""  # nosec B608


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


def advance_session_chunk(connection, entry, top, scan):
    """Fold one rowid chunk; return the unsettled tail rows."""
    low = entry["rowid"]
    high = min(top, low + SESSION_CHUNK_ROWS)
    rows = [tuple(item) for item in connection.execute(INC_SESSION_QUERY, (low, high, scan.since))]
    boundary = settled_boundary(rows, high, scan.now)
    for record in rows:
        if record[-1] <= boundary:
            entry["skipped"] += consume_session_record(entry["sessions"], record[:7], "")
    entry["rowid"] = max(low, boundary)
    scan.checkpoint()
    return [record for record in rows if record[-1] > boundary], high == top


def with_pending(entry, pending):
    """Public rows: settled state plus unsettled rows folded into copies."""
    touched = {record[0] for record in pending}
    working = {sid: copy.deepcopy(row) for sid, row in entry["sessions"].items() if sid in touched}
    for record in pending:
        consume_session_record(working, record[:7], "")
    merged = dict(entry["sessions"])
    merged.update(working)
    return public_rows(merged)


def scan_session_source(db_path, entry, scan):
    """Return (public rows, ok, complete scan, fully persisted)."""
    note_scan(db_path)
    pending = []
    try:
        with readonly_connection(db_path) as connection:
            top = connection.execute("SELECT max(rowid) FROM message").fetchone()[0] or 0
            if top < entry["rowid"]:
                entry.update(rowid=0, sessions={}, skipped=0)
            while entry["rowid"] < top:
                if scan.expired():
                    return public_rows(entry["sessions"]), True, False, False
                pending, reached_top = advance_session_chunk(connection, entry, top, scan)
                if pending:
                    return with_pending(entry, pending), True, reached_top, False
    except (OSError, sqlite3.Error):
        return [], False, False, False
    return public_rows(entry["sessions"]), True, True, True


def session_entry(state, path, scan):
    """Existing or fresh entry for a source; archives reset on identity change."""
    archive = path.name.startswith("opencode-archive")
    entry = state["sessions"].get(str(path))
    if entry is None or (archive and entry.get("identity") != file_identity(path)):
        entry = {"rowid": 0, "sessions": {}, "skipped": 0, "complete": False}
    prune_session_entry(entry, scan.since)
    state["sessions"][str(path)] = entry
    return entry, archive


def source_rows(path, entry, archive, scan):
    identity = file_identity(path) if archive else None
    if archive and entry.get("complete") and entry.get("identity") == identity:
        return public_rows(entry["sessions"]), True, True
    rows, ok, done, persisted = scan_session_source(path, entry, scan)
    if archive and ok and done and persisted:
        entry["complete"], entry["identity"] = True, identity
    return rows, ok, done


def collect_sessions_incremental(home, explicit, state, scan):
    paths = db_paths(home, explicit)
    keys = {str(path) for path in paths}
    state["sessions"] = {key: value for key, value in state["sessions"].items() if key in keys}
    sessions, seen, ok, complete, skipped = [], set(), False, True, 0
    for path in paths:
        entry, archive = session_entry(state, path, scan)
        rows, source_ok, source_done = source_rows(path, entry, archive, scan)
        ok = ok or source_ok
        complete = complete and source_ok and source_done
        skipped += entry["skipped"]
        for row in rows:
            if row["session_id"] not in seen:
                sessions.append(row)
                seen.add(row["session_id"])
    return sessions, ok, complete, skipped


def collect_incremental(home, db_path, state_file, since, now):
    """Return the collected population plus a `complete` flag for the profile run."""
    try:
        budget = float(os.environ.get("AIDEVOPS_SESSION_TIME_BUDGET_S", "240"))
    except ValueError:
        budget = 240.0
    state = load_state(state_file)

    def checkpoint():
        try:
            save_state(state_file, state)
        except OSError as error:
            raise RuntimeError(f"session-time: failed to save checkpoint {state_file}: {error}") from error

    scan = Scan(since, now, time.monotonic() + max(1.0, budget), checkpoint)
    rows, session_ok, sessions_done, skipped = collect_sessions_incremental(home, db_path, state, scan)
    obs_rows, obs_ok, obs_done, obs_skipped = collect_observability_incremental(home, state, scan)
    checkpoint()
    return {
        "sessions": {"": rows},
        "session_ok": {"": session_ok},
        "skipped": {"": skipped},
        "obs_rows": {"": obs_rows},
        "obs_ok": obs_ok,
        "obs_skipped": {"": obs_skipped},
        "complete": sessions_done and obs_done,
    }
