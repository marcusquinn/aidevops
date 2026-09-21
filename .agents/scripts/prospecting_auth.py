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
from dataclasses import dataclass
from pathlib import Path
from typing import Any

AUTH_SCHEMA_VERSION = 1
READ_PERMISSION = "read"
OWNER_PERMISSION = "owner"
TOKEN_PREFIX = "apsr"
SESSION_PREFIX = "apso"


class AuthError(ValueError):
    """Raised when credentials or their requested authority are invalid."""


@dataclass(frozen=True)
class Principal:
    credential_id: str
    kind: str
    projects: frozenset[str]
    permissions: frozenset[str]
    expires_at: int | None = None

    def allows(self, project_id: str, permission: str = READ_PERMISSION) -> bool:
        return permission in self.permissions and project_id in self.projects


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
    prefix: str,
    kind: str,
    projects: tuple[str, ...],
    permissions: tuple[str, ...],
    *,
    ttl_seconds: int | None = None,
    rotated_from: str | None = None,
) -> tuple[str, str | None]:
    credential_id = secrets.token_hex(8)
    secret = secrets.token_urlsafe(32)
    salt = secrets.token_bytes(16)
    csrf = secrets.token_urlsafe(24) if kind == "owner_session" else None
    expires_at = _now() + ttl_seconds if ttl_seconds is not None else None
    database.execute("BEGIN IMMEDIATE")
    try:
        database.execute(
            "INSERT INTO credentials VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            (credential_id, kind, salt, _hash(secret, salt), json.dumps(projects),
             json.dumps(permissions), hashlib.sha256(csrf.encode()).digest() if csrf else None,
             _now(), expires_at, None, rotated_from),
        )
        database.execute(
            "INSERT INTO audit(credential_id,action,occurred_at,detail) VALUES(?,?,?,?)",
            (credential_id, "issued", _now(), json.dumps({"kind": kind, "projects": projects})),
        )
        if rotated_from:
            database.execute(
                "UPDATE credentials SET revoked_at=? WHERE credential_id=? AND revoked_at IS NULL",
                (_now(), rotated_from),
            )
        database.execute("COMMIT")
    except Exception:
        database.execute("ROLLBACK")
        raise
    return f"{prefix}_{credential_id}_{secret}", csrf


def issue_read_key(database: sqlite3.Connection, projects: list[str], *, rotate: str | None = None) -> str:
    token, _csrf = _issue(database, TOKEN_PREFIX, "read_key", _projects(projects), (READ_PERMISSION,), rotated_from=rotate)
    return token


def issue_owner_session(database: sqlite3.Connection, projects: list[str], *, ttl_seconds: int = 3600) -> tuple[str, str]:
    if not 60 <= ttl_seconds <= 86400:
        raise AuthError("owner session TTL must be between 60 and 86400 seconds")
    token, csrf = _issue(database, SESSION_PREFIX, "owner_session", _projects(projects), (READ_PERMISSION, OWNER_PERMISSION), ttl_seconds=ttl_seconds)
    assert csrf is not None
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
    database.execute("BEGIN IMMEDIATE")
    try:
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
        database.execute("COMMIT")
    except Exception:
        database.execute("ROLLBACK")
        raise
