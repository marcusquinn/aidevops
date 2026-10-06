# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Local atomic admission for observed GitHub REST resources, never a data cache.

Only response headers establish quota. Unresolved identities deliberately share
one conservative host scope, rather than granting each token a new allowance.
This database coordinates local processes, not independently configured hosts.
"""

from __future__ import annotations

import hashlib
import os
import sqlite3
import subprocess
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

from gh_transport_capacity import capacity_wait
from gh_transport_identity import quota_owner
from gh_transport_reconcile import reconcile_scope as _reconcile_scope
from gh_transport_recovery import (
    admission_status,
    mark_dead_reservations,
    note_live_window,
    probe_recovers,
    record_budget_transition,
    reserve_probe_allowed,
    revalidation_wait,
)
from gh_transport_schema import SCHEMA_VERSION, ensure_schema

__all__ = [
    "Budget", "Deferred", "admission_status", "credential_identity", "private_directory",
    "process_birth", "quota_owner", "reconcile_scope", "scope_key",
]


class Deferred(Exception):
    """No safe admission is currently available."""

    def __init__(self, message: str, *, retryable: bool = False, retry_at: float | None = None):
        super().__init__(message)
        self.retryable = retryable
        self.retry_at = retry_at


def private_directory(path: Path) -> None:
    if not path.is_absolute() or path.is_symlink():
        raise ValueError("unsafe transport state directory")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.stat().st_uid != os.getuid():
        raise ValueError("transport state directory is not owned by this user")
    path.chmod(0o700)


def scope_key(host: str, owner: str | None = None) -> str:
    # Only trusted launch context may name a quota owner. A credential digest is
    # not a quota owner: two PATs can spend the same user's allowance.
    owner = quota_owner()[0] if owner is None else owner
    return hashlib.sha256(f"{host}\0{owner}".encode()).hexdigest()


def credential_identity(executable: str, host: str) -> tuple[str, bool, dict[str, str]]:
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        try:
            token = subprocess.check_output(
                [executable, "auth", "token", "--hostname", host],
                stderr=subprocess.DEVNULL, timeout=5,
            ).decode().strip()
        except (OSError, ValueError, subprocess.SubprocessError):
            token = "anonymous"
    authenticated = bool(token and token != "anonymous")
    environment = os.environ.copy()
    # Pin only the native child, not a long-lived wrapper or worker parent.
    # Callers reject anonymous identity before execution; authenticated requests
    # hash and execute with exactly the same token.
    environment["GH_TOKEN"] = token
    return hashlib.sha256(f"{host}\0{token}".encode()).hexdigest(), authenticated, environment


def process_birth(pid: int) -> str:
    try:
        value = subprocess.check_output(
            ["ps", "-p", str(pid), "-o", "lstart="],
            stderr=subprocess.DEVNULL, timeout=2,
        ).strip()
        return hashlib.sha256(value).hexdigest() if value else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def _valid_observation(headers: dict[str, str], resource: str, now: float):
    """Return (remaining, reset, limit) from authoritative headers, else None."""
    remaining = headers.get("x-ratelimit-remaining", "")
    reset = headers.get("x-ratelimit-reset", "")
    limit = headers.get("x-ratelimit-limit", "")
    if headers.get("x-ratelimit-resource", "") != resource:
        return None
    if not (remaining.isdecimal() and limit.isdecimal() and reset.isdecimal()):
        return None
    if not 0 <= int(remaining) <= int(limit) <= 1000000:
        return None
    if not now < int(reset) <= now + 86400:
        return None
    return int(remaining), int(reset), int(limit)


class Budget:
    def __init__(self, directory: Path, scope: str, credential: str | None = None,
                 *, attributed: bool = False):
        private_directory(directory)
        self.path = directory / "admission.sqlite3"
        if self.path.is_symlink():
            raise ValueError("unsafe transport state file")
        # O_NOFOLLOW closes the final-component creation race. SQLite then opens
        # this user-owned file beneath a mode-700 directory.
        fd = os.open(self.path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        os.close(fd)
        if self.path.stat().st_uid != os.getuid():
            raise ValueError("transport state file is not owned by this user")
        self.path.chmod(0o600)
        self.db = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        requested_scope = scope
        self.scope = scope
        self.credential = credential or scope
        self.attributed = False
        self.birth = process_birth(os.getpid())
        try:
            self._ensure_schema()
            with self.transaction():
                binding_events = self._bind_scope()
        except BaseException:
            self.db.close()
            raise
        # A configured owner is authoritative only after its requested scope is
        # canonical. A legacy owner->unresolved alias still needs reconciliation.
        self.attributed = attributed and self.scope == requested_scope
        for event in binding_events:
            record_budget_transition(self, *event, event="scope_binding")

    def _ensure_schema(self) -> None:
        ensure_schema(self.db)

    def _root(self, scope: str) -> str:
        for _ in range(256):
            row = self.db.execute("SELECT target FROM alias WHERE scope=?", (scope,)).fetchone()
            if not row:
                return scope
            scope = row[0]
        raise ValueError("quota scope alias cycle")

    def _bind_scope(self) -> list:
        events = []
        self.scope = self._root(self.scope)
        bound = self.db.execute(
            "SELECT scope FROM binding WHERE credential=?", (self.credential,)
        ).fetchone()
        if bound and self._root(bound[0]) != self.scope:
            previous = self._root(bound[0])
            # A known credential cannot get a second allowance by changing from
            # unresolved to configured owner. Merge, never split live evidence.
            for row in self.db.execute(
                "SELECT resource,remaining,reset,observed,blocked_until,quota_limit "
                "FROM quota WHERE scope=?", (self.scope,)
            ).fetchall():
                old = self.db.execute(
                    "SELECT remaining,reset,observed,blocked_until,quota_limit "
                    "FROM quota WHERE scope=? AND resource=?", (previous, row[0])
                ).fetchone()
                values = row[1:] if not old else (
                    min(row[1], old[0]), max(row[2], old[1]), min(row[3], old[2]),
                    max(row[4], old[3]), min(row[5], old[4]),
                )
                self.db.execute("INSERT OR REPLACE INTO quota VALUES(?,?,?,?,?,?,?)",
                                (previous, row[0], *values))
                events.append((
                    {"remaining": old[0], "reset": old[1]} if old else None,
                    {"remaining": row[1], "reset": row[2]},
                    {"remaining": values[0], "reset": values[1]}, False, None,
                ))
            self.db.execute("DELETE FROM quota WHERE scope=?", (self.scope,))
            self.db.execute("UPDATE reservation SET scope=? WHERE scope=?", (previous, self.scope))
            self.db.execute("UPDATE admission_history SET scope=? WHERE scope=?", (previous, self.scope))
            self.db.execute(
                "INSERT INTO pacing SELECT ?,resource,reset,retry_at,remaining FROM pacing WHERE scope=? "
                "ON CONFLICT(scope,resource) DO UPDATE SET reset=MAX(reset,excluded.reset), "
                "retry_at=MAX(retry_at,excluded.retry_at), remaining=MIN(remaining,excluded.remaining)",
                (previous, self.scope),
            )
            self.db.execute("DELETE FROM pacing WHERE scope=?", (self.scope,))
            self.db.execute(
                "INSERT INTO revalidation SELECT ?,resource,started,reservation_id "
                "FROM revalidation WHERE scope=? ON CONFLICT(scope,resource) DO UPDATE SET "
                "started=excluded.started,reservation_id=excluded.reservation_id "
                "WHERE excluded.started > revalidation.started", (previous, self.scope),
            )
            self.db.execute("DELETE FROM revalidation WHERE scope=?", (self.scope,))
            self.db.execute("INSERT OR REPLACE INTO alias VALUES(?,?)", (self.scope, previous))
            self.scope = previous
        self.db.execute("INSERT OR REPLACE INTO binding VALUES(?,?)", (self.credential, self.scope))
        return events

    @contextmanager
    def transaction(self):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            if self.db.execute("PRAGMA user_version").fetchone()[0] != SCHEMA_VERSION:
                raise ValueError("transport state schema changed after initialization")
            self.scope = self._root(self.scope)
            yield
            self.db.execute("COMMIT")
        except Deferred:
            # Admission defers before creating a reservation. Persist only its
            # pacing deadline and dead-executor accounting, never an HTTP grant.
            self.db.execute("COMMIT")
            raise
        except BaseException:
            self.db.execute("ROLLBACK")
            raise

    def acquire(self, resource: str, *, now: float | None = None) -> str:
        now = time.time() if now is None else now
        reservation = uuid.uuid4().hex
        with self.transaction():
            mark_dead_reservations(self, now, process_birth)
            row = self.db.execute(
                "SELECT remaining,reset,observed,blocked_until,quota_limit FROM quota "
                "WHERE scope=? AND resource=?", (self.scope, resource)
            ).fetchone()
            total, active = self.db.execute(
                "SELECT COUNT(*),COALESCE(SUM(uncertain=0),0) FROM reservation "
                "WHERE scope=? AND resource=?",
                (self.scope, resource),
            ).fetchone()
            if row and row[3] > now:
                raise Deferred("server resource cooldown is active", retry_at=row[3])
            if row and row[1] > now and row[0] - total < 1:
                raise Deferred(
                    f"local primary capacity exhausted (remaining={row[0]}, reserved={total}, "
                    f"reset={int(row[1])})", retry_at=row[1],
                )
            if revalidation_wait(self, resource, row, active, now):
                raise Deferred("waiting for serialized quota revalidation",
                               retryable=True, retry_at=now + 1)
            # Expired/missing observations are not a new 5,000-point grant.
            # Permit one serialized real request to obtain fresh headers.
            fresh = row and 0 <= now - row[2] <= 20 and row[1] > now
            if not fresh and active:
                raise Deferred("waiting for an authoritative quota observation", retryable=True)
            probe = self.db.execute(
                "SELECT started FROM revalidation WHERE scope=? AND resource=?",
                (self.scope, resource),
            ).fetchone()
            refresh = bool(row and row[1] > now and
                           reserve_probe_allowed(row, active, total, probe, now))
            # A paced stale balance must not starve its own serialized refresh.
            # Omit only primary pacing evidence: capacity_wait still enforces
            # concurrency/secondary ceilings, and cooldown/exhaustion ran above.
            reason, retry_at = capacity_wait(self, resource, None if refresh else row, total, now)
            if reason:
                raise Deferred(reason, retryable=True, retry_at=retry_at)
            if refresh:
                # A stale positive balance may be refreshed by one causally newer
                # request. This is ordinary admitted work, never a reserve bypass.
                self.db.execute("INSERT OR REPLACE INTO revalidation VALUES(?,?,?,?)",
                                (self.scope, resource, now, reservation))
            self.db.execute(
                "INSERT INTO reservation(id,scope,resource,started,pid,birth,credential) VALUES(?,?,?,?,?,?,?)",
                (reservation, self.scope, resource, now, os.getpid(), self.birth, self.credential),
            )
            self.db.execute("INSERT INTO admission_history VALUES(?,?,?)", (self.scope, resource, now))
            return reservation

    def _accepted_balance(self, reservation: str, resource: str, row, observed: tuple[int, int],
                          headers: dict[str, str], now: float) -> tuple[int, int, float, bool]:
        """Return (available, reset_at, blocked_until, recovered) for a valid response."""
        available, reset_at = observed
        blocked_until = 0.0
        # A bound credential's newer window or a serialized reserve
        # probe may repair stale evidence. Shared/ambiguous owners and
        # same-window late replies retain conservative accounting.
        # /rate_limit is never a grant.
        recovered = probe_recovers(self, reservation, resource, row, reset_at)
        if row and row[1] > now and not recovered:
            # Late responses and unresolved owners with different reset
            # epochs cannot restore quota observed to have been spent.
            # Keep the lower balance paired with its own reset epoch:
            # extending it to another credential's later (sliding)
            # reset would re-stamp stale debt indefinitely (GH#33701).
            if reset_at > row[1]:
                note_live_window(self, resource, reset_at, now)
            if available >= row[0]:
                available, reset_at = row[0], int(row[1])
            blocked_until = row[3]
        retry_after = headers.get("retry-after", "")
        if retry_after.isdecimal():
            blocked_until = max(blocked_until, now + int(retry_after))
        if available == 0:
            blocked_until = max(blocked_until, reset_at)
        return available, reset_at, blocked_until, recovered

    def finish(self, reservation: str, resource: str, headers: dict[str, str],
               *, started: float, now: float | None = None) -> None:
        now = time.time() if now is None else now
        observed = _valid_observation(headers, resource, now)
        with self.transaction():
            if not observed:
                # Uncertain execution may have spent a point. Keep its debt;
                # it is covered only by a later authoritative observation.
                self.db.execute(
                    "UPDATE reservation SET uncertain=1,started=? WHERE id=?",
                    (now, reservation),
                )
                return
            row = self.db.execute(
                "SELECT remaining,reset,observed,blocked_until FROM quota "
                "WHERE scope=? AND resource=?", (self.scope, resource)
            ).fetchone()
            available, reset_at, blocked_until, recovered = self._accepted_balance(
                reservation, resource, row, observed[:2], headers, now)
            self.db.execute(
                "INSERT OR REPLACE INTO quota VALUES(?,?,?,?,?,?,?)",
                (self.scope, resource, available, reset_at, now, blocked_until, observed[2]),
            )
            # This response includes charges for completed unknown requests
            # which ended before it started. Never clear concurrent work.
            self.db.execute(
                "DELETE FROM reservation WHERE scope=? AND resource=? "
                "AND uncertain=1 AND credential=? AND started<?",
                (self.scope, resource, self.credential, started)
            )
            self.db.execute("DELETE FROM reservation WHERE id=?", (reservation,))
        record_budget_transition(
            self,
            {"remaining": row[0], "reset": row[1]} if row else None,
            {"remaining": observed[0], "reset": observed[1]},
            {"remaining": available, "reset": reset_at},
            recovered, bool(row and started >= row[2]),
        )

    def close(self) -> None:
        self.db.close()


def reconcile_scope(directory: Path, unresolved_scope: str, owner_scope: str,
                    *, now: float | None = None) -> dict:
    """Replace ambiguous local evidence with one attributed bootstrap boundary."""
    private_directory(directory)
    return _reconcile_scope(directory, unresolved_scope, owner_scope,
                            context=(now, Deferred))


if __name__ == "__main__":
    from gh_transport_budget_cli import main
    main()
