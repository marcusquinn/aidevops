"""Transactional admission for cooperating callers; not physical writer exclusion.

Only the explicit admission mode uses this API. Observe-only callers still bypass
admission and must not be counted as covered. Closing never authorizes cleanup.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
import os
from pathlib import Path
import sqlite3
import time
from typing import TypeVar
from uuid import UUID, uuid5

from .process import ProcessIdentity
from .refusal import failure_category
from .retirement_fence import require_unfenced
from .storage import LifecycleRegistry, SCHEMA, StoreConflict, encode, identifier

# Bounded wait for a transiently busy registry writer (GH#36921). Each attempt
# also waits up to the store's busy timeout, so total wait stays below
# deadline + one busy timeout. Persistent contention still denies the launch.
CONTENTION_DEADLINE_SECONDS = 30.0
_CONTENTION_PAUSE_SECONDS = (0.1, 0.2, 0.5, 1.0)
_Result = TypeVar("_Result")


def contention_deadline() -> float:
    """Operator-tunable admission wait; 0 restores a single attempt, never fail-open."""
    try:
        value = float(os.environ.get("AIDEVOPS_LIFECYCLE_ADMISSION_WAIT_SECONDS",
                                     CONTENTION_DEADLINE_SECONDS))
    except ValueError:
        value = -1.0
    if not 0 <= value <= 300:  # Also rejects NaN.
        raise ValueError("invalid-admission-wait")
    return value


@dataclass(frozen=True)
class ContentionWait:
    """Bounded writer-contention retry policy; clock and sleep are injectable."""

    deadline: float = CONTENTION_DEADLINE_SECONDS
    on_retry: Callable[[int, Exception], None] | None = None
    clock: Callable[[], float] = time.monotonic
    sleep: Callable[[float], None] = time.sleep


def within_contention_deadline(attempt: Callable[[], _Result],
                               wait: ContentionWait | None = None) -> _Result:
    """Run one transaction, retrying only writer contention until a bounded deadline.

    For admission, a busy writer rolls back the whole transaction, so no attempt
    commits partially. Each retry repeats the open-generation check under the
    writer; an attempt that committed before a lost acknowledgement replays as
    False, never as a second execution authority. Every other refusal, and
    contention past the deadline, propagates so the caller denies launch.
    """
    wait = wait or ContentionWait()
    limit = wait.clock() + wait.deadline
    retries = 0
    while True:
        try:
            return attempt()
        except sqlite3.OperationalError as error:
            pause = _CONTENTION_PAUSE_SECONDS[min(retries, len(_CONTENTION_PAUSE_SECONDS) - 1)]
            if failure_category(error) != "contention" or wait.clock() + pause >= limit:
                raise
            retries += 1
            if wait.on_retry is not None:
                wait.on_retry(retries, error)
        wait.sleep(pause)


class AdmissionClosed(StoreConflict):
    """The generation is absent or no longer admits new runs."""


class AdmissionRegistry:
    def __init__(self, store: LifecycleRegistry):
        self.store = store

    @staticmethod
    def _require_schema(connection: sqlite3.Connection) -> None:
        if connection.execute("PRAGMA user_version").fetchone()[0] != SCHEMA:
            raise ValueError("explicit-schema-upgrade-required")

    def _replayed(self, event_id: str, payload: dict) -> bool:
        """Recognize immutable committed evidence without competing for a writer.

        A miss is only a hint: the writer path must repeat event deduplication
        atomically with admission. A replay never authorizes a second launch or
        reopens a generation, even if another transaction is closing it.
        """
        identifier(event_id)
        with self.store.connection() as connection:
            self._require_schema(connection)
            row = connection.execute(
                "SELECT payload FROM events WHERE event_id=?", (event_id,),
            ).fetchone()
            if row is None:
                return False
            if row["payload"] != encode(payload):
                raise StoreConflict("event-id-payload-conflict")
            return True

    def open_generation(self, event_id: str, generation_id: str, path: Path) -> None:
        """Reserve a canonical path. This does not verify a physical generation."""
        identifier(generation_id)
        if not path.is_absolute() or path.resolve(strict=True) != path or not path.is_dir():
            raise ValueError("canonical-directory-required")
        value = str(path)
        if len(value) > 4096:
            raise ValueError("generation-path-too-long")
        payload = {"type": "open-admission", "generation_id": generation_id, "path": value}
        if self._replayed(event_id, payload):
            return
        with self.store.connection(write=True) as connection:
            self._require_schema(connection)
            require_unfenced(connection, generation_id, value)  # GH#37828 reservation
            if not path.is_dir():
                raise ValueError("canonical-directory-required")
            _, duplicate = self.store._event(connection, event_id, payload)
            if duplicate:
                return  # Replaying an old open must never reopen a closed gate.
            if connection.execute("SELECT 1 FROM generations WHERE generation_id=?", (generation_id,)).fetchone():
                raise StoreConflict("generation-already-exists")
            if connection.execute("SELECT 1 FROM generation_admissions WHERE path=?", (value,)).fetchone():
                raise StoreConflict("path-already-reserved")
            connection.execute("INSERT INTO generations VALUES (?,?)", (generation_id, value))
            connection.execute("INSERT INTO generation_admissions VALUES (?,?,'open')", (generation_id, value))

    def admit(self, run_id: str, identity: ProcessIdentity, generation_id: str,
              expected_path: str | None = None) -> bool:
        """Register atomically; False acknowledges a replay, NEVER a second exec.

        True records a first admission, not successful exec. A caller losing the
        acknowledgement must not blindly launch again on False; recovery requires
        checking the original run. Missing state and DB failures must deny launch.
        """
        namespace = UUID(identifier(run_id))
        identifier(generation_id)
        identity.validate()
        event_id = str(uuid5(namespace, "admit"))
        payload = {
            "type": "admit", "run_id": run_id,
            "generation_id": generation_id, "identity": identity.to_dict(),
            "expected_path": expected_path,
        }
        if self._replayed(event_id, payload):
            return False
        with self.store.connection(write=True) as connection:
            self._require_schema(connection)
            _, duplicate = self.store._event(connection, event_id, payload)
            if duplicate:
                return False
            generation = connection.execute(
                "SELECT path,state FROM generation_admissions WHERE generation_id=?", (generation_id,),
            ).fetchone()
            if generation is None or generation["state"] != "open":
                raise AdmissionClosed("generation-not-open")
            if expected_path is not None and expected_path != generation["path"]:
                raise StoreConflict("generation-path-mismatch")
            self.store._register(connection, str(uuid5(namespace, "register")), run_id, identity)
            self.store._bind(connection, str(uuid5(namespace, "bind")), run_id, generation_id, generation["path"])
            return True

    def authorize_enrolled_only(self, event_id: str, generation_id: str) -> None:
        """Operator-confirmed: close admission for a generation with no owner ever.

        The no-run predicate, the evidence event and the closure share one writer
        transaction, so a racing `admit` either committed first (this refuses) or
        finds the generation closed. Any bound run, live or ended, is ineligible.
        """
        identifier(generation_id)
        creation = str(uuid5(UUID(generation_id), "created-worktree"))
        with self.store.connection(write=True) as connection:
            self._require_schema(connection)
            if not connection.execute(
                "SELECT 1 FROM generation_admissions WHERE generation_id=?",
                (generation_id,),
            ).fetchone():
                raise AdmissionClosed("generation-not-registered")
            if (connection.execute(
                    "SELECT 1 FROM bindings WHERE generation_id=?", (generation_id,),
                ).fetchone() or connection.execute(
                    "SELECT 1 FROM events WHERE event_id=?", (creation,),
                ).fetchone()):
                raise StoreConflict("generation-has-admitted-owner")
            self.store._event(connection, event_id, {
                "type": "enrolled-only-retirement-authorized",
                "generation_id": generation_id, "operator_confirmed": True,
            })
            connection.execute(
                "UPDATE generation_admissions SET state='closed' WHERE generation_id=?",
                (generation_id,),
            )

    def close_generation(
        self, event_id: str, generation_id: str, *,
        expected_ended_runs: tuple[str, ...] | None = None,
    ) -> tuple[str, ...]:
        """Close monotonically; optionally require an unchanged, ended run set.

        Cleanup supplies its observed run IDs. The predicate and closure share
        the admission writer transaction, so a racing new owner prevents closure.
        Omitting the predicate retains explicit controller shutdown semantics.
        """
        identifier(generation_id)
        with self.store.connection(write=True) as connection:
            self._require_schema(connection)
            if not connection.execute("SELECT 1 FROM generation_admissions WHERE generation_id=?", (generation_id,)).fetchone():
                raise AdmissionClosed("generation-not-registered")
            if expected_ended_runs is not None:
                rows = connection.execute(
                    "SELECT r.run_id,r.state FROM runs r JOIN bindings b "
                    "USING(run_id) WHERE b.generation_id=? ORDER BY r.run_id",
                    (generation_id,),
                ).fetchall()
                if (not rows
                        or tuple(row["run_id"] for row in rows)
                        != tuple(sorted(expected_ended_runs))
                        or any(row["state"] != "ended" for row in rows)):
                    raise StoreConflict("generation-not-quiescent")
            self.store._event(connection, event_id, {"type": "close-admission", "generation_id": generation_id})
            connection.execute("UPDATE generation_admissions SET state='closed' WHERE generation_id=?", (generation_id,))
            return tuple(row[0] for row in connection.execute(
                "SELECT r.run_id FROM runs r JOIN bindings b USING(run_id) "
                "WHERE b.generation_id=? AND r.state!='ended' ORDER BY r.run_id", (generation_id,),
            ))
