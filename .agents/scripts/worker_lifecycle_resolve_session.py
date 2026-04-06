#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Resolve OpenCode session ID from a session title.

Extracted from the inline heredoc in worker-lifecycle-common.sh
(_resolve_session_id_from_cmd) to reduce shell nesting depth (GH#17561).

Reads env vars:
    DB_PATH  - path to the OpenCode SQLite database
    TITLE    - session title to look up (exact match first, then LIKE)

Prints: session ID to stdout, or empty string if not found.
"""

import os
import sqlite3

db = os.environ["DB_PATH"]
title = os.environ["TITLE"]
conn = sqlite3.connect(db)
conn.execute("PRAGMA busy_timeout=5000")
cur = conn.cursor()
cur.execute(
    "SELECT id FROM session WHERE title = ? ORDER BY time_created DESC LIMIT 1",
    (title,),
)
row = cur.fetchone()
if not row:
    cur.execute(
        "SELECT id FROM session WHERE title LIKE ? ORDER BY time_created DESC LIMIT 1",
        (f"%{title}%",),
    )
    row = cur.fetchone()
print(row[0] if row else "")
