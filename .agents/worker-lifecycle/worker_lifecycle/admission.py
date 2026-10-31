"""Transactional admission for cooperating callers; not physical writer exclusion.

Only the explicit admission mode uses this API. Observe-only callers still bypass
admission and must not be counted as covered. Closing never authorizes cleanup.
"""

from __future__ import annotations

from pathlib import Path
import sqlite3
from uuid import UUID, uuid5

from .process import ProcessIdentity
from .storage import LifecycleRegistry, SCHEMA, StoreConflict, identifier


class AdmissionClosed(StoreConflict):
    """The generation is absent or no longer admits new runs."""


class AdmissionRegistry:
    def __init__(self, store: LifecycleRegistry):
        self.store = store

    @staticmethod
    def _require_schema(connection: sqlite3.Connection) -> None:
        if connection.execute("PRAGMA user_version").fetchone()[0] != SCHEMA:
            raise ValueError("explicit-schema-upgrade-required")

    def open_generation(self, event_id: str, generation_id: str, path: Path) -> None:
        """Reserve a canonical path. This does not verify a physical generation."""
        identifier(generation_id)
        if not path.is_absolute() or path.resolve(strict=True) != path or not path.is_dir():
            raise ValueError("canonical-directory-required")
        value = str(path)
        if len(value) > 4096:
            raise ValueError("generation-path-too-long")
        with self.store.connection(write=True) as connection:
            self._require_schema(connection)
            _, duplicate = self.store._event(connection, event_id, {
                "type": "open-admission", "generation_id": generation_id, "path": value,
            })
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
        with self.store.connection(write=True) as connection:
            self._require_schema(connection)
            _, duplicate = self.store._event(connection, str(uuid5(namespace, "admit")), {
                "type": "admit", "run_id": run_id,
                "generation_id": generation_id, "identity": identity.to_dict(),
                "expected_path": expected_path,
            })
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

    def close_generation(self, event_id: str, generation_id: str) -> tuple[str, ...]:
        """Close monotonically and return all non-ended bindings in one transaction."""
        identifier(generation_id)
        with self.store.connection(write=True) as connection:
            self._require_schema(connection)
            if not connection.execute("SELECT 1 FROM generation_admissions WHERE generation_id=?", (generation_id,)).fetchone():
                raise AdmissionClosed("generation-not-registered")
            self.store._event(connection, event_id, {"type": "close-admission", "generation_id": generation_id})
            connection.execute("UPDATE generation_admissions SET state='closed' WHERE generation_id=?", (generation_id,))
            return tuple(row[0] for row in connection.execute(
                "SELECT r.run_id FROM runs r JOIN bindings b USING(run_id) "
                "WHERE b.generation_id=? AND r.state!='ended' ORDER BY r.run_id", (generation_id,),
            ))
