#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Atomic ownership writes; caller validation and schema migration stay in Bash."""

from contextlib import closing
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys

import worktree_lifetime_owner as owner_lifetime
import worktree_lifetime_proof as lifetime_proof


def release_completed(args: list[str]) -> int:
    """Release an exact dead lease, never infer completion from PID absence."""
    if len(args) != 5:
        return 1
    database, path, pid, start, created = args
    try:
        with closing(sqlite3.connect(database, isolation_level=None)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT record FROM worktree_managed_lifetimes WHERE path=?", (path,)).fetchone()
            owner_lifetime.require(bool(row), "missing lifetime record")
            record = json.loads(row[0])
            owner_lifetime.require(record.get("manager") == owner_lifetime.MANAGER, "unexpected lifetime manager")
            identity = owner_lifetime.identity(Path(path))
            owner_lifetime.require(record.get("identity") == identity, "lifetime identity changed")
            lifetime_proof.proof(record, identity["source_inode"])
            try:
                os.kill(int(pid), 0)
            except ProcessLookupError:
                pass
            else:
                raise ValueError("owner remains alive")
            cursor = connection.execute(
                """DELETE FROM worktree_owners WHERE worktree_path=? AND owner_pid=?
                   AND COALESCE(owner_process_start, '')=? AND COALESCE(created_at, '')=?""",
                (path, int(pid), start, created))
            connection.execute("COMMIT")
            return 0 if cursor.rowcount == 1 else 1
    except (sqlite3.Error, ValueError, OSError, KeyError, subprocess.SubprocessError):
        return 1


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


def begin_creation_command(args):
    database, path = args
    if not os.path.exists(database):
        return 0  # No registry means there is no old receipt to fence.
    with closing(sqlite3.connect(database, isolation_level=None)) as connection:
        connection.execute("BEGIN IMMEDIATE")
        token = owner_lifetime.begin_creation(connection, str(Path(path).resolve()))
        connection.execute("COMMIT")
    print(token)
    return 0


def write_owner(connection, operation, args):
    if operation == "register":
        connection.execute(
            """INSERT OR REPLACE INTO worktree_owners
            (worktree_path, branch, owner_pid, owner_session, owner_batch,
             task_id, owner_comm, owner_process_start, owner_dead_seen_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, '')""", (args[1], *owner_values(args)))
        return True, ""
    if operation == "claim":
        return True, claim(connection, args)
    if operation == "adopt":
        try:
            os.kill(int(args[9]), 0)
        except ProcessLookupError:
            pass
        else:
            raise ValueError("previous owner remains alive")
        os.kill(int(args[3]), 0)
    return transfer(connection, args), ""


def observe_registered_owner(connection, args, creating):
    final = connection.execute(
        "SELECT owner_pid, owner_session FROM worktree_owners WHERE worktree_path=?",
        (args[1],)).fetchone()
    cleanup = args[6] == "worktree-removal" and re.fullmatch(r"cleanup:[0-9]+", args[4])
    if final == (int(args[3]), args[4]) and not cleanup:
        owner_lifetime.register(connection, args[1], final[0], final[1], creating)


def main(argv: list[str]) -> int:
    try:
        operation, *args = argv
        lifecycle_commands = {"release-completed": release_completed, "begin-create": begin_creation_command}
        if operation in lifecycle_commands:
            return lifecycle_commands[operation](args)
        expected = {"register": 10, "claim": 10, "transfer": 15, "adopt": 15}[operation]
        owner_lifetime.require(len(args) == expected, "invalid ownership arguments")
        # Closing an uncommitted SQLite connection rolls back every write, including
        # generation rotation; the separately committed pre-creation fence remains.
        with closing(sqlite3.connect(args[0], isolation_level=None)) as connection:
            connection.execute("BEGIN IMMEDIATE")
            creating = (operation == "register" and os.environ.get("AIDEVOPS_WORKTREE_CREATING") == "1" and
                        os.environ.get("AIDEVOPS_WORKTREE_MANAGER") != "pulse-cgroup-v1")
            if creating:
                owner_lifetime.prepare_creation(connection, args[1])
            owner_lifetime.check_admission(connection, args[1])
            matched, output = write_owner(connection, operation, args)
            if matched:
                observe_registered_owner(connection, args, creating)
            connection.execute("COMMIT" if matched else "ROLLBACK")
        if output:
            print(output)
        return 0 if matched else 1
    except (sqlite3.Error, ValueError, OSError, KeyError, subprocess.SubprocessError):
        print("Worktree ownership transaction unavailable", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
