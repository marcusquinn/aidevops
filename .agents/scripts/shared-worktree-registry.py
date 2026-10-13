#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Read-only, cross-platform registry queries behind the existing shell API.

Exit codes: 0 = result, 1 = absent owner/database, 2 = unavailable evidence.
This module never migrates schema, claims ownership, or authorizes deletion.
"""

from __future__ import annotations

from contextlib import closing
import os
from pathlib import Path
import sqlite3
import sys


QUERIES = {
    "path": "SELECT worktree_path FROM worktree_owners WHERE worktree_path = ?",
    "snapshot": """SELECT worktree_path, owner_pid, owner_session, owner_batch,
                          task_id, created_at, COALESCE(owner_process_start, '')
                   FROM worktree_owners WHERE worktree_path = ?""",
}


def lookup_row(
    connection: sqlite3.Connection, normalized: str, mode: str
) -> tuple[object, ...] | None:
    """Use the primary key first, scanning only for legacy non-normalized keys."""
    query = QUERIES[mode]
    row = connection.execute(query, (normalized,)).fetchone()
    if row is not None:
        return row
    for (stored_path,) in connection.execute("SELECT worktree_path FROM worktree_owners"):
        if stored_path and os.path.realpath(stored_path) == normalized:
            return connection.execute(query, (stored_path,)).fetchone()
    return None


def database_status(database: Path, mode: str) -> int:
    """Distinguish a missing database from an inaccessible filesystem path."""
    try:
        database.stat()
    except FileNotFoundError:
        return 1 if mode == "snapshot" else 2
    except OSError:
        return 2
    return 0


def read_registry(database: Path, requested_path: str, mode: str) -> tuple[int, str]:
    """Read one consistent snapshot; never conflate I/O or schema errors with absence."""
    if mode not in QUERIES:
        return 2, ""
    status = database_status(database, mode)
    if status:
        return status, ""
    try:
        normalized = os.path.realpath(requested_path)
        # URI encoding preserves literal ?, # and % in filesystem paths. A DB
        # disappearing after stat is an open failure, not a newly created DB.
        uri = database.absolute().as_uri() + "?mode=ro"
        with closing(sqlite3.connect(uri, uri=True)) as connection:
            connection.execute("BEGIN")
            row = lookup_row(connection, normalized, mode)
        if mode == "path":
            return 0, str(row[0]) if row else normalized
        return (1, "") if row is None else (
            0, "|".join("" if value is None else str(value) for value in row[1:])
        )
    except (OSError, ValueError, sqlite3.Error):
        return 2, ""


def main(arguments: list[str]) -> int:
    if len(arguments) != 3:
        return 2
    database, requested_path, mode = arguments
    status, output = read_registry(Path(database), requested_path, mode)
    if status == 0:
        print(output)
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
