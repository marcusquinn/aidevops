#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Versioned, project-scoped credentials for the local prospecting service."""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator

import prospecting_jobs
from prospecting_store import import_document, set_disposition, update_project_version

AUTH_SCHEMA_VERSION = 1
READ_PERMISSION = "read"
OWNER_PERMISSION = "owner"
TOKEN_PREFIX = "apsr"  # nosec B105: public token type marker, not a credential
SESSION_PREFIX = "apso"
JOB_KINDS = frozenset({"scan", "seo-refresh", "insights-refresh", "digest-preview"})


class AuthError(ValueError):
    """Raised when credentials or their requested authority are invalid."""


class OperatorError(ValueError):
    """Raised when an owner request violates the typed operator contract."""

    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


@dataclass(frozen=True)
class Principal:
    credential_id: str
    kind: str
    projects: frozenset[str]
    permissions: frozenset[str]
    expires_at: int | None = None

    def allows(self, project_id: str, permission: str = READ_PERMISSION) -> bool:
        return permission in self.permissions and project_id in self.projects


@dataclass(frozen=True)
class CredentialSpec:
    prefix: str
    kind: str
    projects: tuple[str, ...]
    permissions: tuple[str, ...]
    ttl_seconds: int | None = None


@dataclass(frozen=True)
class JobRequestRecord:
    project_id: str
    request_id: str
    job_kind: str
    digest: str
    payload: str


def _now() -> int:
    return int(time.time())


def _hash(secret: str, salt: bytes) -> bytes:
    return hashlib.scrypt(secret.encode(), salt=salt, n=2**14, r=8, p=1, dklen=32)


def _identifier(value: str, field: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 128:
        raise AuthError(f"{field} is invalid")
    if not all(character.isalnum() or character in "._-" for character in value):
        raise AuthError(f"{field} is invalid")
    return value


def _projects(values: list[str] | tuple[str, ...]) -> tuple[str, ...]:
    if not values or len(values) > 100:
        raise AuthError("at least one project scope is required")
    return tuple(sorted({_identifier(value, "project_id") for value in values}))


@contextmanager
def _transaction(database: sqlite3.Connection) -> Iterator[None]:
    database.execute("BEGIN IMMEDIATE")
    try:
        yield
        database.execute("COMMIT")
    except Exception:
        database.execute("ROLLBACK")
        raise


def connect(root: Path) -> sqlite3.Connection:
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if root.is_symlink():
        raise AuthError("auth root cannot be a symlink")
    os.chmod(root, 0o700)
    path = root / "prospecting-auth.db"
    if path.is_symlink():
        raise AuthError("auth database cannot be a symlink")
    database = sqlite3.connect(path, isolation_level=None, timeout=5)
    database.row_factory = sqlite3.Row
    database.execute("PRAGMA busy_timeout=5000")
    database.execute("PRAGMA foreign_keys=ON")
    database.execute("PRAGMA journal_mode=WAL")
    os.chmod(path, 0o600)
    current = int(database.execute("PRAGMA user_version").fetchone()[0])
    if current not in (0, AUTH_SCHEMA_VERSION):
        database.close()
        raise AuthError(f"unsupported auth schema version: {current}")
    if current == 0:
        database.executescript(
            """BEGIN IMMEDIATE;
            CREATE TABLE credentials (
                credential_id TEXT PRIMARY KEY, kind TEXT NOT NULL,
                salt BLOB NOT NULL, secret_hash BLOB NOT NULL,
                projects_json TEXT NOT NULL, permissions_json TEXT NOT NULL,
                csrf_hash BLOB, created_at INTEGER NOT NULL, expires_at INTEGER,
                revoked_at INTEGER, rotated_from TEXT);
            CREATE TABLE audit (
                event_id INTEGER PRIMARY KEY AUTOINCREMENT,
                credential_id TEXT NOT NULL, action TEXT NOT NULL,
                occurred_at INTEGER NOT NULL, detail TEXT NOT NULL);
            CREATE TABLE service_settings (
                project_id TEXT NOT NULL, setting_kind TEXT NOT NULL,
                version INTEGER NOT NULL, value_json TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY(project_id,setting_kind));
            CREATE TABLE operator_requests (
                project_id TEXT NOT NULL, request_id TEXT NOT NULL,
                request_kind TEXT NOT NULL, payload_digest TEXT NOT NULL,
                payload_json TEXT NOT NULL, created_at INTEGER NOT NULL,
                PRIMARY KEY(project_id,request_id));
            PRAGMA user_version=1;
            COMMIT;"""
        )
    return database


def _issue(
    database: sqlite3.Connection,
    spec: CredentialSpec,
    rotated_from: str | None = None,
) -> tuple[str, str | None]:
    credential_id = secrets.token_hex(8)
    secret = secrets.token_urlsafe(32)
    salt = secrets.token_bytes(16)
    csrf = secrets.token_urlsafe(24) if spec.kind == "owner_session" else None
    expires_at = _now() + spec.ttl_seconds if spec.ttl_seconds is not None else None
    with _transaction(database):
        database.execute(
            "INSERT INTO credentials VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            (credential_id, spec.kind, salt, _hash(secret, salt), json.dumps(spec.projects),
             json.dumps(spec.permissions), hashlib.sha256(csrf.encode()).digest() if csrf else None,
             _now(), expires_at, None, rotated_from),
        )
        database.execute(
            "INSERT INTO audit(credential_id,action,occurred_at,detail) VALUES(?,?,?,?)",
            (credential_id, "issued", _now(), json.dumps({"kind": spec.kind, "projects": spec.projects})),
        )
        if rotated_from:
            cursor = database.execute(
                "UPDATE credentials SET revoked_at=? WHERE credential_id=? AND revoked_at IS NULL",
                (_now(), rotated_from),
            )
            if cursor.rowcount != 1:
                raise AuthError("rotation source is missing or already revoked")
    return f"{spec.prefix}_{credential_id}_{secret}", csrf


def issue_read_key(database: sqlite3.Connection, projects: list[str], *, rotate: str | None = None) -> str:
    spec = CredentialSpec(TOKEN_PREFIX, "read_key", _projects(projects), (READ_PERMISSION,))
    token, _csrf = _issue(database, spec, rotate)
    return token


def issue_owner_session(database: sqlite3.Connection, projects: list[str], *, ttl_seconds: int = 3600) -> tuple[str, str]:
    if not 60 <= ttl_seconds <= 86400:
        raise AuthError("owner session TTL must be between 60 and 86400 seconds")
    spec = CredentialSpec(SESSION_PREFIX, "owner_session", _projects(projects),
                          (READ_PERMISSION, OWNER_PERMISSION), ttl_seconds)
    token, csrf = _issue(database, spec)
    if csrf is None:
        raise AuthError("owner session CSRF creation failed")
    return token, csrf


def _authenticate(database: sqlite3.Connection, token: str, prefix: str, kind: str) -> tuple[Principal, sqlite3.Row]:
    parts = token.split("_", 2) if isinstance(token, str) else []
    if len(parts) != 3 or parts[0] != prefix:
        raise AuthError("invalid credentials")
    row = database.execute("SELECT * FROM credentials WHERE credential_id=? AND kind=?", (parts[1], kind)).fetchone()
    if row is None or row["revoked_at"] is not None or (row["expires_at"] is not None and row["expires_at"] <= _now()):
        raise AuthError("invalid credentials")
    if not hmac.compare_digest(bytes(row["secret_hash"]), _hash(parts[2], bytes(row["salt"]))):
        raise AuthError("invalid credentials")
    principal = Principal(row["credential_id"], kind, frozenset(json.loads(row["projects_json"])),
                          frozenset(json.loads(row["permissions_json"])), row["expires_at"])
    return principal, row


def authenticate_read(database: sqlite3.Connection, authorization: str) -> Principal:
    if not isinstance(authorization, str) or not authorization.startswith("Bearer "):
        raise AuthError("authentication required")
    principal, _row = _authenticate(database, authorization[7:], TOKEN_PREFIX, "read_key")
    return principal


def authenticate_owner(database: sqlite3.Connection, cookie_token: str, csrf: str) -> Principal:
    principal, row = _authenticate(database, cookie_token, SESSION_PREFIX, "owner_session")
    if not isinstance(csrf, str) or not row["csrf_hash"] or not hmac.compare_digest(bytes(row["csrf_hash"]), hashlib.sha256(csrf.encode()).digest()):
        raise AuthError("invalid CSRF token")
    return principal


def revoke(database: sqlite3.Connection, credential_id: str) -> None:
    credential_id = _identifier(credential_id, "credential_id")
    with _transaction(database):
        cursor = database.execute(
            "UPDATE credentials SET revoked_at=? WHERE credential_id=? AND revoked_at IS NULL",
            (_now(), credential_id),
        )
        if cursor.rowcount != 1:
            raise AuthError("credential is missing or already revoked")
        database.execute(
            "INSERT INTO audit(credential_id,action,occurred_at,detail) VALUES(?,?,?,?)",
            (credential_id, "revoked", _now(), "{}"),
        )


@dataclass(frozen=True)
class OperatorContext:
    """Owner-only typed mutation dispatcher with service-local request state."""

    database: sqlite3.Connection
    auth_database: sqlite3.Connection
    principal: Principal

    def execute(self, method: str, parts: list[str], value: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        if method not in {"POST", "PATCH", "PUT"}:
            raise OperatorError(405, "method_not_allowed", "operator method is not supported")
        if parts == ["v1", "operator", "projects"] and method == "POST":
            return self._create(value)
        if len(parts) < 4 or parts[:3] != ["v1", "operator", "projects"]:
            raise OperatorError(404, "not_found", "resource not found")
        project_id = parts[3]
        self._authorize(project_id)
        handlers = {
            (5, "profile", "PATCH"): self._document,
            (5, "discovery", "PATCH"): self._document,
            (6, "leads", "PATCH"): self._disposition,
            (5, "jobs", "POST"): self._job,
            (5, "alerts", "PUT"): self._alert,
        }
        handler = handlers.get((len(parts), parts[4] if len(parts) > 4 else "", method))
        if handler is None:
            raise OperatorError(404, "not_found", "resource not found")
        return handler(project_id, parts, value)

    def _authorize(self, project_id: str) -> None:
        if not self.principal.allows(project_id, OWNER_PERMISSION):
            raise OperatorError(404, "not_found", "resource not found")
        row = self.database.execute("SELECT 1 FROM projects WHERE project_id=?", (project_id,)).fetchone()
        if row is None:
            raise OperatorError(404, "not_found", "resource not found")

    def _create(self, value: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        project = value.get("project") if isinstance(value.get("project"), dict) else {}
        project_id = project.get("project_id", "")
        if not self.principal.allows(project_id, OWNER_PERMISSION):
            raise OperatorError(404, "not_found", "resource not found")
        result = import_document(self.database, value)
        return 201, result

    def _document(self, project_id: str, parts: list[str], value: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        _exact(value, {"expected_version", "value"})
        changed = update_project_version(
            self.database, project_id, parts[4], value.get("expected_version"), value.get("value")
        )
        return 200, {"project_id": project_id, "kind": parts[4], "version": changed}

    def _disposition(self, project_id: str, parts: list[str], value: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        _exact(value, {"disposition", "expected_version"})
        changed = set_disposition(
            self.database, project_id, parts[5], value.get("disposition"), value.get("expected_version")
        )
        return 200, {"project_id": project_id, "lead_id": parts[5], "version": changed}

    def _job(self, project_id: str, _parts: list[str], value: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        _exact(value, {"request_id", "job_kind", "budget"})
        request_id = _identifier(value.get("request_id"), "request_id")
        job_kind = value.get("job_kind")
        if job_kind not in JOB_KINDS:
            raise OperatorError(400, "invalid_request", "job_kind is not allowed")
        planned = prospecting_jobs.plan({
            "project_id": project_id,
            "jobs": [{"id": job_kind, "cadence": "manual", "enabled": True, "budget": value.get("budget", {})}],
        })
        payload = json.dumps(planned["jobs"][0], sort_keys=True, separators=(",", ":"))
        digest = hashlib.sha256(payload.encode()).hexdigest()
        result = self._record_request(JobRequestRecord(project_id, request_id, job_kind, digest, payload))
        return 202, result

    def _record_request(self, record: JobRequestRecord) -> dict[str, Any]:
        with _transaction(self.auth_database):
            existing = self.auth_database.execute(
                "SELECT payload_digest,payload_json FROM operator_requests WHERE project_id=? AND request_id=?",
                (record.project_id, record.request_id),
            ).fetchone()
            result = self._request_result(record, existing)
        return result

    def _request_result(self, record: JobRequestRecord, existing: sqlite3.Row | None) -> dict[str, Any]:
        if existing:
            if existing["payload_digest"] != record.digest:
                raise OperatorError(409, "idempotency_conflict", "request_id was already used with different input")
            plan, replayed = json.loads(existing["payload_json"]), True
        else:
            self.auth_database.execute(
                "INSERT INTO operator_requests VALUES(?,?,?,?,?,?)",
                (record.project_id, record.request_id, record.job_kind, record.digest, record.payload, _now()),
            )
            self.auth_database.execute(
                "INSERT INTO audit(credential_id,action,occurred_at,detail) VALUES(?,?,?,?)",
                (self.principal.credential_id, "job_requested", _now(),
                 json.dumps({"project_id": record.project_id, "request_id": record.request_id,
                             "job_kind": record.job_kind})),
            )
            plan, replayed = json.loads(record.payload), False
        return {"project_id": record.project_id, "request_id": record.request_id, "status": "requested",
                "replayed": replayed, "plan": plan}

    def _alert(self, project_id: str, _parts: list[str], value: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        _exact(value, {"expected_version", "enabled", "minimum_score"})
        expected = value.get("expected_version")
        score = value.get("minimum_score")
        if isinstance(expected, bool) or not isinstance(expected, int) or expected < 0:
            raise OperatorError(400, "invalid_request", "expected_version is invalid")
        if not isinstance(value.get("enabled"), bool):
            raise OperatorError(400, "invalid_request", "enabled must be boolean")
        if isinstance(score, bool) or not isinstance(score, (int, float)) or not 0 <= score <= 100:
            raise OperatorError(400, "invalid_request", "minimum_score is invalid")
        payload = json.dumps({"enabled": value["enabled"], "minimum_score": score}, sort_keys=True)
        changed = self._store_alert(project_id, expected, payload)
        return 200, {"project_id": project_id, "version": changed, "alerts": json.loads(payload)}

    def _store_alert(self, project_id: str, expected: int, payload: str) -> int:
        with _transaction(self.auth_database):
            existing = self.auth_database.execute(
                "SELECT version FROM service_settings WHERE project_id=? AND setting_kind='alerts'", (project_id,)
            ).fetchone()
            current = existing["version"] if existing else 0
            if current != expected:
                raise OperatorError(409, "stale_version", "alert configuration version is stale")
            changed = current + 1
            self.auth_database.execute(
                "INSERT INTO service_settings VALUES(?,?,?,?,?) ON CONFLICT(project_id,setting_kind) DO UPDATE SET version=excluded.version,value_json=excluded.value_json,updated_at=excluded.updated_at",
                (project_id, "alerts", changed, payload, _now()),
            )
        return changed


def _exact(value: dict[str, Any], allowed: set[str]) -> None:
    extra = sorted(set(value) - allowed)
    if extra:
        raise OperatorError(400, "unsupported_fields", "unsupported fields: " + ", ".join(extra))
