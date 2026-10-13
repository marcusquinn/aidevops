#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Atomic ownership writes; caller validation and schema migration stay in Bash."""

from contextlib import closing
import os
import sqlite3
import sys


def owner_values(args: list[str]) -> tuple[str, int, str, str, str, str, str]:
    return (args[2], int(args[3]), args[4], args[5], args[6], args[7], args[8])


def claim(connection: sqlite3.Connection, args: list[str]) -> str:
    path = args[1]
    values = owner_values(args)
    pid, session = values[1:3]
    existing = connection.execute(
        """SELECT owner_pid, COALESCE(owner_session, '')
           FROM worktree_owners WHERE worktree_path = ?""", (path,)
    ).fetchone()
    if os.name == "posix" and existing and isinstance(existing[0], int) and existing[0] != pid:
        try:
            os.kill(existing[0], 0)
        except ProcessLookupError:
            connection.execute(
                """DELETE FROM worktree_owners WHERE worktree_path = ?
                   AND owner_pid = ? AND COALESCE(owner_session, '') = ?""",
                (path, existing[0], existing[1]),
            )
        except (PermissionError, OSError):
            # An inaccessible process is not evidence of a dead owner.
            pass
    connection.execute(
        """UPDATE worktree_owners SET branch = ?, owner_pid = ?, owner_session = ?,
           owner_batch = ?, task_id = ?, owner_comm = ?, owner_process_start = ?,
           owner_dead_seen_at = '' WHERE worktree_path = ?
           AND (owner_pid = ? OR (? AND owner_session = ?))""",
        (*values, path, pid, args[9] == "1", session),
    )
    connection.execute(
        """INSERT OR IGNORE INTO worktree_owners
           (worktree_path, branch, owner_pid, owner_session, owner_batch,
            task_id, owner_comm, owner_process_start, owner_dead_seen_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, '')""", (path, *values)
    )
    final = connection.execute(
        """SELECT owner_pid, COALESCE(owner_session, '')
           FROM worktree_owners WHERE worktree_path = ?""", (path,)
    ).fetchone()
    return f"{final[0]}|{final[1]}" if final else ""


def transfer(connection: sqlite3.Connection, args: list[str]) -> bool:
    cursor = connection.execute(
        """UPDATE worktree_owners
           SET branch = ?, owner_pid = ?, owner_session = ?, owner_batch = ?,
               task_id = ?, owner_comm = ?, owner_process_start = ?,
               owner_dead_seen_at = '',
               created_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
           WHERE worktree_path = ? AND owner_pid = ?
             AND COALESCE(owner_session, '') = ?
             AND COALESCE(owner_batch, '') = ?
             AND COALESCE(task_id, '') = ?
             AND COALESCE(created_at, '') = ?
             AND COALESCE(owner_process_start, '') = ?""",
        (*owner_values(args), args[1], int(args[9]), *args[10:]),
    )
    return cursor.rowcount == 1


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in ("claim", "transfer"):
        return 1
    operation, args = argv[0], argv[1:]
    if len(args) != (10 if operation == "claim" else 15):
        return 1
    output = ""
    try:
        with closing(sqlite3.connect(args[0], isolation_level=None)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                if operation == "claim":
                    output = claim(connection, args)
                    matched = True
                else:
                    matched = transfer(connection, args)
                connection.execute("COMMIT" if matched else "ROLLBACK")
            except Exception:
                if connection.in_transaction:
                    connection.execute("ROLLBACK")
                raise
        if output:
            print(output)
        return 0 if matched else 1
    except (sqlite3.Error, ValueError, OSError):
        print("Worktree ownership transaction unavailable", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
