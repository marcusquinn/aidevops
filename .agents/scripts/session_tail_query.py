#!/usr/bin/env python3
"""Query OpenCode session DB and classify the session tail.

Extracted from the inline heredoc in worker-lifecycle-common.sh
(_run_session_tail_python) to reduce function complexity and enable
independent testing.

Reads env vars:
    SESSION_TAIL_DB_PATH   - path to the OpenCode SQLite database
    SESSION_TAIL_TITLE     - session title fragment to match
    SESSION_TAIL_TIMEOUT   - recent-activity window in seconds
    SESSION_TAIL_LIMIT     - max number of 'part' rows to inspect

Prints: "classification|summary" to stdout.
"""

import json
import os
import re
import sqlite3
import sys
import time

PROVIDER_MARKERS = (
    "rate limit",
    "rate-limit",
    "429",
    "backoff",
    "retrying",
    "retry after",
    "overloaded",
    "temporarily unavailable",
    "connection reset",
    "timed out",
    "timeout",
    "econnreset",
    "etimedout",
    "service unavailable",
)


def collapse(value, limit=120):
    """Collapse whitespace and truncate a string for log-safe display."""
    value = re.sub(r"\s+", " ", value or "").strip()
    if len(value) > limit:
        value = value[: limit - 3] + "..."
    return value.replace("|", "/")


def find_session(cursor, session_title):
    """Find the most recent session matching *session_title*.

    Returns (session_id, resolved_title) or None.
    """
    cursor.execute(
        """
        SELECT id, title
        FROM session
        WHERE title LIKE ?
        ORDER BY time_created DESC
        LIMIT 1
        """,
        (f"%{session_title}%",),
    )
    return cursor.fetchone()


def count_recent_messages(cursor, session_id, timeout_seconds):
    """Count messages created within the recent-activity window."""
    cursor.execute(
        """
        SELECT COUNT(*)
        FROM message
        WHERE session_id = ?
          AND (CASE WHEN time_created > 20000000000
               THEN time_created / 1000
               ELSE time_created END)
              > strftime('%s', 'now') - ?
        """,
        (session_id, timeout_seconds),
    )
    return int(cursor.fetchone()[0] or 0)


def fetch_recent_parts(cursor, session_id, part_limit):
    """Fetch the most recent *part_limit* parts, oldest-first."""
    cursor.execute(
        """
        SELECT data, time_created
        FROM part
        WHERE session_id = ?
        ORDER BY time_created DESC
        LIMIT ?
        """,
        (session_id, part_limit),
    )
    return list(reversed(cursor.fetchall()))


def parse_parts(part_rows):
    """Parse raw part rows into display entries and a search blob.

    Returns (entries, search_blob, newest_part_time).
    """
    entries = []
    search_blob = []
    newest_part_time = 0

    for raw_data, part_time in part_rows:
        newest_part_time = max(newest_part_time, int(part_time or 0))
        data = json.loads(raw_data)
        part_type = data.get("type", "unknown")

        if part_type == "text":
            preview = collapse(data.get("text", ""))
            if preview:
                entries.append(f'text:"{preview}"')
                search_blob.append(preview.lower())
        elif part_type == "tool":
            state = data.get("state", {})
            status = collapse(str(state.get("status", "unknown")), 24)
            description = collapse(
                str(state.get("input", {}).get("description", ""))
            )
            tool_name = collapse(str(data.get("tool", "tool")), 32)
            if description:
                entries.append(f'tool:{tool_name}({status}) "{description}"')
                search_blob.append(description.lower())
            else:
                entries.append(f"tool:{tool_name}({status})")
        elif part_type == "step-finish":
            reason = collapse(str(data.get("reason", "done")), 32)
            entries.append(f"step-finish:{reason}")
        elif part_type == "step-start":
            entries.append("step-start")
        elif part_type == "reasoning":
            entries.append("reasoning")
        else:
            entries.append(collapse(part_type, 32))

    if not entries:
        entries.append("no-parts")

    return entries, search_blob, newest_part_time


def classify_session(recent_count, search_blob):
    """Classify session state as active, provider-waiting, or stalled."""
    joined_blob = " ".join(search_blob)
    if recent_count > 0:
        return "active"
    if any(marker in joined_blob for marker in PROVIDER_MARKERS):
        return "provider-waiting"
    return "stalled"


def format_summary(classification, resolved_title, recent_count,
                   newest_part_time, entries):
    """Build the final 'classification|summary' output line."""
    age_seconds = (
        max(0, int(time.time()) - newest_part_time)
        if newest_part_time
        else -1
    )
    tail_summary = " > ".join(entries[-5:])
    summary = (
        f'session="{collapse(resolved_title, 80)}"; '
        f"recent_messages={recent_count}; "
        f"newest_part_age={age_seconds}s; "
        f"tail={tail_summary}"
    )
    return f"{classification}|{summary}"


def main():
    """Entry point: read env vars, query DB, print classification."""
    db_path = os.environ["SESSION_TAIL_DB_PATH"]
    session_title = os.environ["SESSION_TAIL_TITLE"]
    timeout_seconds = int(os.environ["SESSION_TAIL_TIMEOUT"])
    part_limit = int(os.environ["SESSION_TAIL_LIMIT"])

    try:
        conn = sqlite3.connect(db_path)
        conn.execute("PRAGMA busy_timeout=5000")
        cursor = conn.cursor()

        session_row = find_session(cursor, session_title)
        if not session_row:
            print("none|No OpenCode session found")
            return

        session_id, resolved_title = session_row
        recent_count = count_recent_messages(
            cursor, session_id, timeout_seconds
        )
        part_rows = fetch_recent_parts(cursor, session_id, part_limit)
    except sqlite3.Error as exc:
        print(
            f"none|Session evidence query failed: "
            f"{collapse(str(exc), 120)}"
        )
        return

    entries, search_blob, newest_part_time = parse_parts(part_rows)
    classification = classify_session(recent_count, search_blob)
    print(
        format_summary(
            classification, resolved_title, recent_count,
            newest_part_time, entries,
        )
    )


if __name__ == "__main__":
    main()
