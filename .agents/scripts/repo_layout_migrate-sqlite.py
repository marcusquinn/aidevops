# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Inspect migration-relevant OpenCode SQLite data without modifying it."""

from __future__ import annotations

import os
import sqlite3
from pathlib import Path
from typing import Any

from repo_layout_common import MigrationError


def sqlite_schema(connection: sqlite3.Connection) -> dict[str, list[str]]:
    """Return only the migration-relevant SQLite table columns."""
    result: dict[str, list[str]] = {}
    for table in ("project", "session"):
        try:
            rows = connection.execute(f"PRAGMA table_info({table})").fetchall()
        except sqlite3.Error as exc:
            raise MigrationError(f"Could not inspect SQLite table: {table}") from exc
        if rows:
            result[table] = [str(row[1]) for row in rows]
    return result


def validated_sql_target(table: str, column: str) -> tuple[str, str]:
    """Allow only the two fixed OpenCode path columns."""
    if (table, column) not in {("project", "worktree"), ("session", "directory")}:
        raise MigrationError("Receipt contains an unsupported database target")
    return table, column


def sqlite_consumer(path: Path, mappings: dict[str, str]) -> dict[str, Any]:
    """Capture relevant exact-path SQLite rows and schema."""
    if any((path.is_symlink(), not path.is_file(), path.stat().st_uid != os.getuid())):
        raise MigrationError(f"Unsafe OpenCode database: {path}")
    uri = f"file:{path}?mode=ro"
    try:
        connection = sqlite3.connect(uri, uri=True, timeout=2)
        schema = sqlite_schema(connection)
        rows = sqlite_consumer_rows(connection, schema, mappings)
        integrity = connection.execute("PRAGMA integrity_check").fetchone()
    except sqlite3.Error as exc:
        raise MigrationError(f"Could not inspect OpenCode database: {path}") from exc
    finally:
        if "connection" in locals():
            connection.close()
    if not integrity or integrity[0] != "ok":
        raise MigrationError(f"SQLite integrity check failed: {path}")
    return {"path": str(path), "schema": schema, "rows": rows}


def sqlite_consumer_rows(
    connection: sqlite3.Connection,
    schema: dict[str, list[str]],
    mappings: dict[str, str],
) -> list[dict[str, str]]:
    """Read migration-relevant exact-path rows from a validated database."""
    rows: list[dict[str, str]] = []
    for table, column in (("project", "worktree"), ("session", "directory")):
        if table not in schema or "id" not in schema[table] or column not in schema[table]:
            continue
        if table == "project":
            query = "SELECT id, worktree FROM project WHERE worktree = ?"
        elif "parent_id" in schema[table]:
            query = "SELECT id, directory FROM session WHERE directory = ? AND parent_id IS NULL"
        else:
            query = "SELECT id, directory FROM session WHERE directory = ?"
        for old_path in mappings:
            for row_id, value in connection.execute(query, (old_path,)).fetchall():
                rows.append(
                    {
                        "table": table,
                        "column": column,
                        "id": str(row_id),
                        "value": str(value),
                    }
                )
    return rows
