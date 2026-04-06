#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Count OpenCode session messages within a time window.

Extracted from the inline heredocs in worker-lifecycle-common.sh
(_count_recent_opencode_messages, _count_worker_messages) to reduce
shell nesting depth (GH#17561).

Reads env vars:
    DB_PATH   - path to the OpenCode SQLite database
    MODE      - "recent" (match by title) or "session" (match by session ID)
    MATCH     - title fragment (MODE=recent) or session ID (MODE=session)
    WINDOW    - time window in seconds

Prints: integer message count to stdout.
"""

import os
import sqlite3

db = os.environ["DB_PATH"]
mode = os.environ.get("MODE", "recent")
match = os.environ.get("MATCH", "")
window = int(os.environ.get("WINDOW", "180"))

conn = sqlite3.connect(db)
conn.execute("PRAGMA busy_timeout=5000")
cur = conn.cursor()

if mode == "session":
    cur.execute(
        "SELECT COUNT(*) FROM message m"
        " WHERE m.session_id = ?"
        " AND (CASE WHEN m.time_created > 20000000000"
        "      THEN m.time_created / 1000 ELSE m.time_created END)"
        " > strftime('%s', 'now') - ?",
        (match, window),
    )
else:
    cur.execute(
        "SELECT COUNT(*) FROM message m JOIN session s ON m.session_id = s.id"
        " WHERE s.title LIKE ?"
        " AND (CASE WHEN m.time_created > 20000000000"
        "      THEN m.time_created / 1000 ELSE m.time_created END)"
        " >= strftime('%s', 'now') - ?",
        (f"%{match}%", window),
    )

print(cur.fetchone()[0] or 0)
