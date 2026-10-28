"""SQLite storage for the lifecycle registry; no actual ownership or Git operations.

Event ingestion and its projection commit together. Observations are sampled
outside transactions and applied only against the exact run version sampled.
"""

from collections.abc import Iterator
from contextlib import contextmanager
import json
import os
from pathlib import Path
import sqlite3
import stat
import sys
from uuid import UUID, uuid4, uuid5

from .process import ProcessIdentity, ProcessObservation


APPLICATION_ID = 0x574C4353
SCHEMA = 1
MAX_EVENT_BYTES = 16384


class StoreConflict(ValueError):
    """An idempotency key, identity or expected version conflicts with storage."""


class StoreCapacity(ValueError):
    """Journal admission is full; existing evidence and replay remain intact."""


def identifier(value: str) -> str:
    if not isinstance(value, str) or str(UUID(value)) != value:
        raise ValueError("invalid-identifier")
    return value


def encode(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def _private(path: Path, directory: bool = False) -> None:
    info = path.lstat()
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if not kind(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("state-path-must-be-private-and-owned")


class LifecycleRegistry:
    def __init__(self, directory: Path):
        self.directory = directory.absolute()
        _private(self.directory, directory=True)
        self.path = self.directory / "registry.sqlite3"
        _private(self.path)

    @classmethod
    def initialize(cls, directory: Path, max_events: int = 10000) -> "LifecycleRegistry":
        # Explicit init only. Never mkdir parents or reuse an existing directory.
        if type(max_events) is not int or not 1 <= max_events <= 100000:  # pylint: disable=unidiomatic-typecheck  # Reject bool
            raise ValueError("invalid-event-limit")
        directory = directory.absolute()
        if directory.parent.resolve(strict=True) != directory.parent:
            raise ValueError("state-parent-must-be-canonical")
        directory.mkdir(mode=0o700)
        descriptor = os.open(directory / "registry.sqlite3", os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(descriptor)
        store = cls(directory)
        connection = store._connect()
        try:
            store._durability(connection)
            connection.execute("BEGIN IMMEDIATE")
            connection.execute(f"PRAGMA application_id={APPLICATION_ID}")
            connection.execute(f"PRAGMA user_version={SCHEMA}")
            connection.execute("CREATE TABLE metadata (installation_id TEXT NOT NULL, mode TEXT NOT NULL CHECK(mode='observe-only'), max_events INTEGER NOT NULL CHECK(max_events BETWEEN 1 AND 100000))")
            connection.execute("INSERT INTO metadata VALUES (?, 'observe-only', ?)", (str(uuid4()), max_events))
            connection.execute("CREATE TABLE events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT UNIQUE NOT NULL, payload TEXT NOT NULL, recorded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')))")
            connection.execute("CREATE TABLE runs (run_id TEXT PRIMARY KEY, identity TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('bound','ended')), version INTEGER NOT NULL, checked_sequence INTEGER NOT NULL DEFAULT 0, observation TEXT)")
            connection.execute("CREATE INDEX unfinished ON runs(state, checked_sequence, run_id)")
            connection.execute("CREATE TABLE generations (generation_id TEXT PRIMARY KEY, path TEXT NOT NULL)")
            connection.execute("CREATE TABLE bindings (run_id TEXT NOT NULL REFERENCES runs(run_id), generation_id TEXT NOT NULL REFERENCES generations(generation_id), PRIMARY KEY(run_id,generation_id))")
            connection.commit()
        finally:
            connection.close()
        return store

    def _connect(self) -> sqlite3.Connection:
        _private(self.directory, directory=True)
        _private(self.path)
        connection = sqlite3.connect(self.path.as_uri() + "?mode=rw", uri=True, timeout=2, isolation_level=None)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys=ON")
        return connection

    @staticmethod
    def _durability(connection: sqlite3.Connection) -> None:
        if connection.execute("PRAGMA journal_mode=WAL").fetchone()[0] != "wal":
            raise ValueError("wal-unavailable")
        connection.execute("PRAGMA synchronous=FULL")
        if connection.execute("PRAGMA synchronous").fetchone()[0] != 2:
            raise ValueError("full-synchronous-unavailable")
        if sys.platform == "darwin":
            connection.execute("PRAGMA fullfsync=ON")
            connection.execute("PRAGMA checkpoint_fullfsync=ON")
            if connection.execute("PRAGMA fullfsync").fetchone()[0] != 1:
                raise ValueError("fullfsync-unavailable")

    @contextmanager
    def connection(self, write: bool = False) -> Iterator[sqlite3.Connection]:
        connection = self._connect()
        try:
            if connection.execute("PRAGMA application_id").fetchone()[0] != APPLICATION_ID:
                raise ValueError("not-a-worker-lifecycle-database")
            if connection.execute("PRAGMA user_version").fetchone()[0] != SCHEMA:
                raise ValueError("unsupported-store-schema")
            if write:
                self._durability(connection)
            connection.execute("BEGIN IMMEDIATE" if write else "BEGIN")
            metadata = connection.execute("SELECT installation_id,mode FROM metadata").fetchall()
            if len(metadata) != 1 or metadata[0]["mode"] != "observe-only":
                raise ValueError("invalid-store-metadata")
            identifier(metadata[0]["installation_id"])
            yield connection
            connection.commit()
        except BaseException:
            connection.rollback()
            raise
        finally:
            connection.close()

    def installation_id(self) -> str:
        with self.connection() as connection:
            return connection.execute("SELECT installation_id FROM metadata").fetchone()[0]

    @staticmethod
    def _event(connection: sqlite3.Connection, event_id: str, payload: dict) -> tuple[int, bool]:
        identifier(event_id)
        value = encode(payload)
        if len(value.encode("utf-8")) > MAX_EVENT_BYTES:
            raise ValueError("event-payload-too-large")
        old = connection.execute("SELECT sequence,payload FROM events WHERE event_id=?", (event_id,)).fetchone()
        if old is not None:
            if old["payload"] != value:
                raise StoreConflict("event-id-payload-conflict")
            return old["sequence"], True
        count = connection.execute("SELECT count(*) FROM events").fetchone()[0]
        maximum = connection.execute("SELECT max_events FROM metadata").fetchone()[0]
        if count >= maximum:
            raise StoreCapacity("journal-event-limit-reached")
        cursor = connection.execute("INSERT INTO events(event_id,payload) VALUES (?,?)", (event_id, value))
        if cursor.lastrowid is None:
            raise RuntimeError("event-sequence-unavailable")
        return cursor.lastrowid, False

    def register(self, event_id: str, run_id: str, identity: ProcessIdentity) -> None:
        with self.connection(write=True) as connection:
            self._register(connection, event_id, run_id, identity)

    def _register(self, connection: sqlite3.Connection, event_id: str, run_id: str, identity: ProcessIdentity) -> None:
        identifier(run_id)
        identity.validate()
        payload = {"type": "register", "run_id": run_id, "identity": identity.to_dict()}
        installation = connection.execute("SELECT installation_id FROM metadata").fetchone()[0]
        if identity.installation_id != installation:
            raise StoreConflict("foreign-installation")
        _, duplicate = self._event(connection, event_id, payload)
        if duplicate:
            return
        if connection.execute("SELECT 1 FROM runs WHERE run_id=?", (run_id,)).fetchone():
            raise StoreConflict("run-already-registered")
        connection.execute("INSERT INTO runs(run_id,identity,state,version) VALUES (?,?,'bound',1)",
                           (run_id, encode(identity.to_dict())))

    def bind(self, event_id: str, run_id: str, generation_id: str, path: str) -> None:
        with self.connection(write=True) as connection:
            self._bind(connection, event_id, run_id, generation_id, path)

    def _bind(self, connection: sqlite3.Connection, event_id: str, run_id: str, generation_id: str, path: str) -> None:
        identifier(run_id)
        identifier(generation_id)
        if not isinstance(path, str) or len(path) > 4096 or not Path(path).is_absolute() or "\0" in path:
            raise ValueError("absolute-generation-path-required")
        payload = {"type": "bind", "run_id": run_id, "generation_id": generation_id, "path": path}
        _, duplicate = self._event(connection, event_id, payload)
        if duplicate:
            return
        run = connection.execute("SELECT state FROM runs WHERE run_id=?", (run_id,)).fetchone()
        if run is None or run[0] != "bound":
            raise StoreConflict("run-not-bound")
        old = connection.execute("SELECT path FROM generations WHERE generation_id=?", (generation_id,)).fetchone()
        if old is not None and old[0] != path:
            raise StoreConflict("generation-path-conflict")
        connection.execute("INSERT OR IGNORE INTO generations VALUES (?,?)", (generation_id, path))
        connection.execute("INSERT OR IGNORE INTO bindings VALUES (?,?)", (run_id, generation_id))
        connection.execute("UPDATE runs SET version=version+1 WHERE run_id=?", (run_id,))

    def register_attempt(self, run_id: str, identity: ProcessIdentity, generation_id: str, path: str) -> None:
        """Commit process evidence and its hypothetical binding together, before exec.

        Retry with the same run ID and payload, including after lost acknowledgement.
        Deterministic event IDs preserve existing event formats and deduplication.
        A committed attempt does not prove exec succeeded or the worker is ready.
        """
        namespace = UUID(identifier(run_id))
        with self.connection(write=True) as connection:
            self._register(connection, str(uuid5(namespace, "register")), run_id, identity)
            self._bind(connection, str(uuid5(namespace, "bind")), run_id, generation_id, path)

    def pending(self, limit: int = 100) -> list[dict]:
        if type(limit) is not int or not 1 <= limit <= 1000:  # pylint: disable=unidiomatic-typecheck  # Reject bool
            raise ValueError("invalid-batch-limit")
        with self.connection() as connection:
            return [dict(row) for row in connection.execute(
                "SELECT run_id,identity,version FROM runs WHERE state='bound' ORDER BY checked_sequence,run_id LIMIT ?", (limit,))]

    @staticmethod
    def _next_check(connection: sqlite3.Connection) -> int:
        # Scheduling order is independent of journal growth. Otherwise an
        # unchanged batch would keep the same cursor and starve later runs.
        return int(connection.execute("SELECT COALESCE(MAX(checked_sequence),0)+1 FROM runs WHERE state='bound'").fetchone()[0])

    def refresh_unchanged(self, run_id: str, version: int, result: ProcessObservation) -> bool:
        """Refresh only concurrency/rotation metadata; retain existing evidence."""
        identifier(run_id)
        if type(version) is not int or version < 1:  # pylint: disable=unidiomatic-typecheck
            raise ValueError("invalid-run-version")
        with self.connection(write=True) as connection:
            row = connection.execute("SELECT state,version,observation FROM runs WHERE run_id=?", (run_id,)).fetchone()
            if row is None or row["state"] != "bound" or row["version"] != version:
                raise StoreConflict("stale-observation")
            if result.status not in {"alive", "unknown"} or row["observation"] != encode(result.to_dict()):
                return False
            connection.execute("UPDATE runs SET version=version+1, checked_sequence=? WHERE run_id=?",
                               (self._next_check(connection), run_id))
            return True

    def observe(self, event_id: str, run_id: str, version: int, result: ProcessObservation) -> None:
        identifier(run_id)
        if type(version) is not int or version < 1:  # pylint: disable=unidiomatic-typecheck  # Reject bool
            raise ValueError("invalid-run-version")
        if result.status not in {"alive", "ended", "unknown"} or not isinstance(result.reason, str) or not 0 < len(result.reason) <= 128:
            raise ValueError("invalid-observation")
        payload = {"type": "observe", "run_id": run_id, "version": version, "result": result.to_dict()}
        with self.connection(write=True) as connection:
            _, duplicate = self._event(connection, event_id, payload)
            if duplicate:
                return
            state = "ended" if result.status == "ended" else "bound"
            cursor = connection.execute(
                "UPDATE runs SET state=?, version=version+1, checked_sequence=?, observation=? WHERE run_id=? AND version=? AND state='bound'",
                (state, self._next_check(connection), encode(result.to_dict()), run_id, version))
            if cursor.rowcount != 1:
                raise StoreConflict("stale-observation")

    def summary(self) -> dict:
        with self.connection() as connection:
            count = connection.execute("SELECT count(*) FROM events").fetchone()[0]
            maximum = connection.execute("SELECT max_events FROM metadata").fetchone()[0]
            return {"mode": "observe-only", "runs": dict(connection.execute("SELECT state,count(*) FROM runs GROUP BY state").fetchall()),
                    "events": count, "event_limit": maximum,
                    "journal_full": count >= maximum,
                    "last_event_at": connection.execute("SELECT recorded_at FROM events ORDER BY sequence DESC LIMIT 1").fetchone()[0] if count else None,
                    "bindings": connection.execute("SELECT count(*) FROM bindings").fetchone()[0],
                    "conflicting_generations": connection.execute("SELECT count(*) FROM (SELECT b.generation_id FROM bindings b JOIN runs r USING(run_id) WHERE r.state='bound' GROUP BY b.generation_id HAVING count(*)>1)").fetchone()[0],
                    "cleanup_authorized": False}
