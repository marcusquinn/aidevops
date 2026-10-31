#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Atomic ownership writes; caller validation and schema migration stay in Bash."""

from contextlib import closing
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys

import worktree_lifetime_owner as owner_lifetime
import worktree_lifetime_proof as lifetime_proof


def release_session(args: list[str]) -> int:
    """Release only this live server generation's deleted-session ownership."""
    if len(args) != 4:
        return 1
    database, pid, session, proof = args
    if not re.fullmatch(r"[1-9][0-9]*", pid) or not re.fullmatch(r"ses_[A-Za-z0-9_-]+", session) or not proof:
        return 1
    try:
        # Resolve once and reuse a shell-free argv containing only a validated PID.
        ps = shutil.which("ps")
        if not ps or not Path(ps).is_absolute():
            raise ValueError("absolute process viewer unavailable")
        command = [ps, "-p", pid, "-o", "lstart="]
        observed = subprocess.check_output(  # nosec B603 -- absolute ps, fixed flags, digits-only PID, no shell.
            command, text=True, timeout=5,
            env={**os.environ, "LC_ALL": "C", "TZ": "UTC"}, stderr=subprocess.DEVNULL)
        if " ".join(observed.split()) != proof:
            return 1
        # The registry uses Linux start ticks, but portable lstart elsewhere.
        if Path("/proc").is_dir():
            start = owner_lifetime.process_identity(int(pid))
        else:
            # Unlike the plugin's UTC proof, the shell registry uses ambient TZ.
            registry_start = subprocess.check_output(  # nosec B603 -- same resolved ps and validated argv, no shell.
                command, text=True, timeout=5,
                env={**os.environ, "LC_ALL": "C"}, stderr=subprocess.DEVNULL)
            start = " ".join(registry_start.split())
        if Path(database).is_file():
            with closing(sqlite3.connect(Path(database).resolve().as_uri() + "?mode=rw", uri=True)) as connection:
                connection.execute(
                    """DELETE FROM worktree_owners WHERE owner_pid=? AND owner_session=?
                       AND COALESCE(owner_process_start, '')=?""", (int(pid), session, start))
                connection.commit()
        return 0
    except (sqlite3.Error, ValueError, OSError, subprocess.SubprocessError):
        return 1


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
    process_start = values[6]
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
           AND ((owner_pid = ? AND (owner_session = '' OR owner_session = ?
                OR (? <> '' AND COALESCE(owner_process_start, '') <> ''
                    AND owner_process_start <> ?)))
                OR (? AND owner_session = ?))""",
        (*values, path, pid, session, process_start, process_start,
         args[9] == "1", session),
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
        output = claim(connection, args)
        return output == f"{int(args[3])}|{args[4]}", output
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
    stage = "arguments"
    try:
        operation, *args = argv
        lifecycle_commands = {"release-completed": release_completed, "release-session": release_session,
                              "begin-create": begin_creation_command}
        if operation in lifecycle_commands:
            return lifecycle_commands[operation](args)
        expected = {"register": 10, "claim": 10, "transfer": 15, "adopt": 15}[operation]
        owner_lifetime.require(len(args) == expected, "invalid ownership arguments")
        # Closing an uncommitted SQLite connection rolls back every write, including
        # generation rotation; the separately committed pre-creation fence remains.
        with closing(sqlite3.connect(args[0], isolation_level=None)) as connection:
            stage = "begin"
            connection.execute("BEGIN IMMEDIATE")
            creating = (operation == "register" and os.environ.get("AIDEVOPS_WORKTREE_CREATING") == "1" and
                        os.environ.get("AIDEVOPS_WORKTREE_MANAGER") != "pulse-cgroup-v1")
            if creating:
                owner_lifetime.prepare_creation(connection, args[1])
            stage = "admission"
            owner_lifetime.check_admission(connection, args[1])
            stage = "write"
            matched, output = write_owner(connection, operation, args)
            if matched:
                stage = "observe"
                observe_registered_owner(connection, args, creating)
            stage = "commit"
            connection.execute("COMMIT" if matched else "ROLLBACK")
        if output:
            print(output)
        return 0 if matched else (2 if operation == "claim" else 1)
    except (sqlite3.Error, ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        print("Worktree ownership transaction unavailable", file=sys.stderr)
        # Do not emit exception messages: they may contain private paths or SQL.
        # Keep transaction failures distinct from a proven different live owner.
        print(f"WORKTREE_OWNERSHIP_ERROR_STAGE={stage}", file=sys.stderr)
        print(f"WORKTREE_OWNERSHIP_ERROR_TYPE={type(error).__name__}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
