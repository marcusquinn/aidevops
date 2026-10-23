#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bounded read-only ownership evidence; contention never authorizes retirement."""

from contextlib import closing
from pathlib import Path
import sqlite3
import sys


def is_contention(error):
    # Extended result codes retain the primary code in their low byte.
    code = getattr(error, "sqlite_errorcode", None)
    if code is not None:
        return code & 0xff in (5, 6)  # SQLITE_BUSY, SQLITE_LOCKED
    # Python <3.11 does not expose sqlite_errorcode. Match only SQLite's
    # exact contention messages, never arbitrary substrings or I/O errors.
    return isinstance(error, sqlite3.OperationalError) and str(error) in (
        "database is locked", "database table is locked", "database schema is locked")


def owner_state(database, source_path):
    path = Path(database)
    try:
        if not path.is_file() or path.is_symlink():
            return "unavailable"
        with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro",
                                     uri=True, timeout=3)) as db:
            row = db.execute("SELECT COUNT(*) FROM worktree_owners WHERE worktree_path = ?",
                             (source_path,)).fetchone()
        return "active" if row[0] else "clear"
    except sqlite3.Error as error:
        return "busy" if is_contention(error) else "unavailable"
    except (OSError, ValueError):
        return "unavailable"


if __name__ == "__main__":
    print(owner_state(sys.argv[1], sys.argv[2]) if len(sys.argv) == 3 else "unavailable")
