"""Lifecycle journal appends, archive-first retention and capacity maintenance."""

from __future__ import annotations

from contextlib import closing
import hashlib
import json
import os
import sqlite3
import sys
from uuid import uuid4

from .filesystem import checked_directory
from .storage import (
    ADMISSION_EVENT_NEED, DEFAULT_MAX_EVENTS, LEGACY_DEFAULT_MAX_EVENTS, MAX_EVENT_BYTES,
    LifecycleRegistry, StoreCapacity, StoreConflict, encode, identifier,
)


def append_event(connection: sqlite3.Connection, event_id: str, payload: dict) -> tuple[int, bool]:
    """Preserve replay conflicts before checking capacity or appending evidence."""
    identifier(event_id)
    value = encode(payload)
    if len(value.encode("utf-8")) > MAX_EVENT_BYTES:
        raise ValueError("event-payload-too-large")
    old = connection.execute("SELECT sequence,payload FROM events WHERE event_id=?", (event_id,)).fetchone()
    if old is not None:
        if old["payload"] != value:
            raise StoreConflict("event-id-payload-conflict")
        return old["sequence"], True
    archived = None
    if connection.execute("SELECT 1 FROM sqlite_master WHERE name='archived_event_ids'").fetchone():
        archived = connection.execute("SELECT payload_sha256 FROM archived_event_ids WHERE event_id=?",
                                      (event_id,)).fetchone()
        if archived and archived[0] != hashlib.sha256(value.encode("utf-8")).hexdigest():
            raise StoreConflict("event-id-payload-conflict")
    # Archived replay must conflict before capacity checking or appending.
    if payload.get("type") in {"register", "bind", "admit", "observe"} and connection.execute(
            "SELECT 1 FROM runs WHERE run_id=? AND state='ended'", (payload.get("run_id"),),
    ).fetchone():
        raise StoreConflict("run-already-registered" if payload["type"] in {"register", "admit"}
                            else "run-not-bound")
    if archived:
        return 0, True  # Historical sequence is in the archive, not the digest tombstone.
    count = connection.execute("SELECT count(*) FROM events").fetchone()[0]
    maximum = LifecycleRegistry._event_limit(connection, lift=True)
    if count >= maximum:
        raise StoreCapacity("journal-event-limit-reached")
    cursor = connection.execute("INSERT INTO events(event_id,payload) VALUES (?,?)", (event_id, value))
    if cursor.lastrowid is None:
        raise RuntimeError("event-sequence-unavailable")
    return cursor.lastrowid, False


def automatic_compaction(store: LifecycleRegistry, connection: sqlite3.Connection) -> None:
    count = connection.execute("SELECT count(*) FROM events").fetchone()[0]
    maximum = store._event_limit(connection)
    short = maximum - count < ADMISSION_EVENT_NEED
    if short or count * 10 >= maximum * 9:
        try:
            store._compact(connection, store.retention_seconds(), apply=True)
        except (OSError, ValueError):
            # Archive/retention failures precede journal mutations.
            # Maintenance is best effort until admission needs room.
            if short:
                raise
            print("[worker-lifecycle] automatic-compaction-skipped", file=sys.stderr)


def compact(store: LifecycleRegistry, connection: sqlite3.Connection, age: int, *, apply: bool) -> dict:
    """Archive bounded batches; a rollback may leave duplicate archive evidence.

    Each new file is an immutable append to the archive set, never rewritten.
    Keeping projections prevents archived register/bind/admit replays from
    resurrecting ended owners. Final retirement, plan and preservation receipts
    stay online because retirement retries still read them before returning.
    """
    if not isinstance(age, int) or isinstance(age, bool) or not 0 <= age <= 315360000:
        raise ValueError("invalid-retention-age")
    rows = connection.execute(
        "SELECT e.* FROM events e JOIN runs r ON r.run_id=json_extract(e.payload,'$.run_id') "
        "WHERE r.state='ended' AND julianday(e.recorded_at)<=julianday('now',?) "
        "AND json_extract(e.payload,'$.type') IN ('register','bind','admit','observe') "
        "AND NOT EXISTS (SELECT 1 FROM bindings own JOIN bindings peer USING(generation_id) "
        "JOIN runs live ON live.run_id=peer.run_id WHERE own.run_id=r.run_id AND live.state='bound') "
        "ORDER BY e.sequence LIMIT 1000", (f"-{age} seconds",),
    ).fetchall()
    # Schema 1 has no admission table. A shared retirement set avoids rescanning
    # the entire journal for every candidate; GROUP BY permits indexed lookups.
    reservations = ([list(row) for row in connection.execute(
        "SELECT generation_id,path FROM generation_admissions")] if connection.execute(
        "SELECT 1 FROM sqlite_master WHERE name='generation_admissions'").fetchone()
        else [])
    rows += connection.execute(
        "WITH reservations AS (SELECT json_extract(value,'$[0]') AS generation_id, "
        "json_extract(value,'$[1]') AS path FROM json_each(?)), retired AS ("
        "SELECT json_extract(payload,'$.type') AS kind, "
        "json_extract(payload,'$.generation_id') AS generation_id, "
        "json_extract(payload,'$.archive') AS archive FROM events "
        "WHERE json_extract(payload,'$.type') IN ('worktree-retired','legacy-worktree-retired') "
        "AND julianday(recorded_at)<=julianday('now',?) GROUP BY kind,generation_id,archive) "
        "SELECT e.* FROM events e WHERE julianday(e.recorded_at)<=julianday('now',?) "
        "AND ((json_extract(e.payload,'$.type') IN "
        "('close-admission','created-worktree','retirement-removing',"
        "'worktree-recovery-authorized') AND EXISTS ("
        "SELECT 1 FROM generations g JOIN retired ON retired.generation_id=g.generation_id "
        "WHERE g.generation_id=json_extract(e.payload,'$.generation_id') "
        "AND retired.kind='worktree-retired' "
        "AND NOT EXISTS (SELECT 1 FROM reservations a WHERE a.generation_id=g.generation_id) "
        "AND NOT EXISTS (SELECT 1 FROM bindings b JOIN runs r USING(run_id) "
        "WHERE b.generation_id=g.generation_id AND r.state='bound'))) "
        "OR (json_extract(e.payload,'$.type') IN ('legacy-worktree-archive','legacy-worktree-removal-planned') "
        "AND EXISTS (SELECT 1 FROM retired WHERE retired.kind='legacy-worktree-retired' "
        "AND retired.archive=json_extract(e.payload,'$.archive')) "
        "AND NOT EXISTS (SELECT 1 FROM reservations a "
        "WHERE a.path=json_extract(e.payload,'$.source') OR a.generation_id IN "
        "(SELECT value FROM json_each(e.payload,'$.generations'))) "
        "AND NOT EXISTS (SELECT 1 FROM generations g JOIN bindings b USING(generation_id) "
        "JOIN runs r USING(run_id) WHERE r.state='bound' AND (g.path=json_extract(e.payload,'$.source') "
        "OR g.generation_id IN (SELECT value FROM json_each(e.payload,'$.generations')))))) "
        "ORDER BY e.sequence LIMIT 1000", (encode(reservations), f"-{age} seconds", f"-{age} seconds"),
    ).fetchall()
    result: dict[str, object] = {"eligible_events": len(rows), "archived_events": 0,
                                 "archive": None, "dry_run": not apply, "cleanup_authorized": False}
    if not apply or not rows:
        return result
    evidence = {"schema": 1, "installation_id": connection.execute(
        "SELECT installation_id FROM metadata").fetchone()[0],
        "events": [dict(row) for row in rows]}
    checksum = hashlib.sha256(encode(evidence).encode("utf-8")).hexdigest()
    document = encode({"evidence": evidence, "sha256": checksum}).encode("utf-8")
    archive = store.directory / f"events-archive-{uuid4()}.json"
    with checked_directory(store.directory) as directory_fd:
        descriptor = os.open(archive.name, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW,
                             0o600, dir_fd=directory_fd)
        with os.fdopen(descriptor, "w+b") as stream:
            stream.write(document)
            stream.flush()
            os.fsync(stream.fileno())
            stream.seek(0)
            verified = json.load(stream)
            if (verified != {"evidence": evidence, "sha256": checksum}
                    or hashlib.sha256(encode(verified["evidence"]).encode("utf-8")).hexdigest()
                    != verified["sha256"]):
                raise StoreConflict("event-archive-verification-failed")
        os.fsync(directory_fd)
    # Small digest tombstones retain global event-ID conflict protection,
    # without retaining unbounded full payloads in the admission journal.
    connection.execute("CREATE TABLE IF NOT EXISTS archived_event_ids "
                       "(event_id TEXT PRIMARY KEY, payload_sha256 TEXT NOT NULL)")
    connection.executemany("INSERT INTO archived_event_ids VALUES (?,?)", [
        (row["event_id"], hashlib.sha256(row["payload"].encode("utf-8")).hexdigest()) for row in rows])
    connection.executemany("DELETE FROM events WHERE sequence=? AND event_id=?",
                           [(row["sequence"], row["event_id"]) for row in rows])
    result.update(archived_events=len(rows), archive=archive.name)
    return result


def raise_capacity(store: LifecycleRegistry, connection: sqlite3.Connection, maximum: int, *, apply: bool) -> dict:
    """Verify a standalone backup before increasing the stored journal limit."""
    current = connection.execute("SELECT max_events FROM metadata").fetchone()[0]
    count = connection.execute("SELECT count(*) FROM events").fetchone()[0]
    minimum = max(current + 1, count, store._event_limit(connection))
    if (not isinstance(maximum, int) or isinstance(maximum, bool)
            or not minimum <= maximum <= DEFAULT_MAX_EVENTS):
        raise ValueError("capacity-must-increase-within-schema-limit")
    # This value identifies historical defaults and is lifted on event writes.
    if maximum == LEGACY_DEFAULT_MAX_EVENTS:
        raise ValueError("capacity-target-reserved-for-legacy-lift")
    backup = None
    if apply:
        backup = store.directory / f"capacity-backup-{uuid4()}.sqlite3"
        descriptor = os.open(backup, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(descriptor)
        with closing(store._connect()) as source, closing(sqlite3.connect(backup)) as target:
            source.backup(target)
            if (target.execute("PRAGMA integrity_check").fetchall() != [("ok",)]
                    or target.execute("SELECT count(*) FROM events").fetchone()[0] != count
                    or target.execute("SELECT max_events FROM metadata").fetchone()[0] != current):
                raise StoreConflict("capacity-backup-verification-failed")
            target.execute("PRAGMA journal_mode=DELETE")
        from .upgrade import _sync

        _sync(backup)
        _sync(store.directory)
        connection.execute("UPDATE metadata SET max_events=?", (maximum,))
    return {"previous_limit": current, "event_limit": maximum, "dry_run": not apply,
            "backup": backup.name if backup else None, "cleanup_authorized": False}
