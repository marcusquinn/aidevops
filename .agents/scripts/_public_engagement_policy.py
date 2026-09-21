#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Strict, provider-neutral validation for bounded public-engagement grants."""

from __future__ import annotations

import hashlib
import json
import sqlite3
from dataclasses import dataclass
from typing import Any, Mapping

MODES = ("disabled", "exact-draft", "policy")
ALLOWED_ACTIONS = frozenset({"post", "reply"})
MAX_RULE_AGE_SECONDS = 7 * 24 * 60 * 60


class PolicyError(ValueError):
    """Raised when policy input cannot confer publishing authority."""


class EngagementServiceError(PolicyError):
    """Typed error for the owner and executor service boundary."""

    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


def canonical_json(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def digest(value: object) -> str:
    return hashlib.sha256(canonical_json(value).encode()).hexdigest()


def _identifier(value: object, field: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 128:
        raise PolicyError(f"{field} is invalid")
    if not all(character.isalnum() or character in "._:-" for character in value):
        raise PolicyError(f"{field} is invalid")
    return value


def _strings(value: object, field: str, *, maximum: int = 100) -> tuple[str, ...]:
    if not isinstance(value, list) or not value or len(value) > maximum:
        raise PolicyError(f"{field} must be a non-empty bounded list")
    result = tuple(sorted({_identifier(item, field) for item in value}))
    if "*" in result:
        raise PolicyError(f"{field} cannot contain wildcards")
    return result


def _positive(value: object, field: str, maximum: int = 10000) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 < value <= maximum:
        raise PolicyError(f"{field} must be a positive bounded integer")
    return value


@dataclass(frozen=True)
class Grant:
    grant_id: str
    revision: int
    owner_id: str
    project_id: str
    corpus_id: str
    connection_id: str
    account_id: str
    communities: tuple[str, ...]
    actions: tuple[str, ...]
    not_before: int
    expires_at: int
    window_seconds: int
    account_cap: int
    community_cap: int
    thread_cooldown_seconds: int
    thread_turn_cap: int
    disclosure: str
    rules_max_age_seconds: int
    enabled: bool
    policy_hash: str


def parse_grant(document: Mapping[str, Any]) -> Grant:
    """Validate one exact grant document and return its hash-bound form."""
    expected = {
        "grant_id", "revision", "owner_id", "project_id", "corpus_id",
        "provider", "connection_id", "account_id", "communities", "actions",
        "not_before", "expires_at", "window_seconds", "account_cap",
        "community_cap", "thread_cooldown_seconds", "thread_turn_cap",
        "disclosure", "rules_max_age_seconds", "enabled",
    }
    if set(document) != expected:
        raise PolicyError("grant fields do not match the versioned policy contract")
    if document.get("provider") != "reddit":
        raise PolicyError("delegated engagement supports only Reddit")
    actions = _strings(document.get("actions"), "actions", maximum=2)
    if not set(actions).issubset(ALLOWED_ACTIONS):
        raise PolicyError("grant contains a prohibited action")
    revision = _positive(document.get("revision"), "revision")
    not_before = document.get("not_before")
    expires_at = document.get("expires_at")
    if any(isinstance(item, bool) or not isinstance(item, int) or item < 0 for item in (not_before, expires_at)):
        raise PolicyError("grant validity window is invalid")
    if expires_at <= not_before:
        raise PolicyError("grant expiry must follow its start")
    disclosure = document.get("disclosure")
    if not isinstance(disclosure, str) or not disclosure.strip() or len(disclosure) > 256:
        raise PolicyError("grant requires a bounded disclosure marker")
    enabled = document.get("enabled")
    if not isinstance(enabled, bool):
        raise PolicyError("enabled must be boolean")
    rules_age = _positive(document.get("rules_max_age_seconds"), "rules_max_age_seconds", MAX_RULE_AGE_SECONDS)
    normalized = dict(document)
    normalized["communities"] = list(_strings(document.get("communities"), "communities"))
    normalized["actions"] = list(actions)
    return Grant(
        _identifier(document.get("grant_id"), "grant_id"), revision,
        _identifier(document.get("owner_id"), "owner_id"),
        _identifier(document.get("project_id"), "project_id"),
        _identifier(document.get("corpus_id"), "corpus_id"),
        _identifier(document.get("connection_id"), "connection_id"),
        _identifier(document.get("account_id"), "account_id"),
        tuple(normalized["communities"]), tuple(normalized["actions"]),
        not_before, expires_at,
        _positive(document.get("window_seconds"), "window_seconds", 31 * 24 * 60 * 60),
        _positive(document.get("account_cap"), "account_cap"),
        _positive(document.get("community_cap"), "community_cap"),
        _positive(document.get("thread_cooldown_seconds"), "thread_cooldown_seconds", 31 * 24 * 60 * 60),
        _positive(document.get("thread_turn_cap"), "thread_turn_cap"),
        disclosure.strip(), rules_age, enabled, digest(normalized),
    )


def preview(document: Mapping[str, Any], current_time: int) -> dict[str, Any]:
    mode = document.get("mode", "disabled")
    if mode not in MODES:
        raise PolicyError("unsupported engagement mode")
    grants = document.get("grants", [])
    if not isinstance(grants, list):
        raise PolicyError("grants must be a list")
    parsed = [parse_grant(item) for item in grants]
    active = [grant for grant in parsed if grant.enabled and grant.not_before <= current_time < grant.expires_at]
    return {
        "schema": "aidevops.public-engagement-policy/v1",
        "mode": mode,
        "default_sends": 0,
        "grant_count": len(parsed),
        "active_grant_count": len(active) if mode == "policy" else 0,
        "grant_hashes": [grant.policy_hash for grant in parsed],
    }


def _service_identifier(value: object, field: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 128:
        raise EngagementServiceError(400, "invalid_request", f"{field} is invalid")
    if not all(character.isalnum() or character in "._-" for character in value):
        raise EngagementServiceError(400, "invalid_request", f"{field} is invalid")
    return value


def _exact_service_fields(value: Mapping[str, Any], allowed: set[str]) -> None:
    if set(value) - allowed:
        raise EngagementServiceError(400, "invalid_request", "request contains unsupported fields")


def _grant_setting_value(
    value: Mapping[str, Any], grant_id: str, project_id: str, owner_id: str
) -> dict[str, Any]:
    if value.get("operation") == "revoke":
        _exact_service_fields(value, {"operation", "expected_version"})
        return {"grant_id": grant_id, "state": "revoked"}
    _exact_service_fields(value, {"expected_version", "grant"})
    grant_value = value.get("grant")
    if not isinstance(grant_value, dict):
        raise EngagementServiceError(400, "invalid_request", "grant must be an object")
    try:
        grant = parse_grant(grant_value)
    except PolicyError as error:
        raise EngagementServiceError(400, "invalid_request", str(error)) from error
    route_scope = (grant.grant_id, grant.project_id, grant.owner_id)
    if route_scope != (grant_id, project_id, owner_id):
        raise EngagementServiceError(
            400, "invalid_request", "grant scope does not match its owner route"
        )
    return {"grant": grant_value, "policy_hash": grant.policy_hash, "state": "active"}


def change_service_grant(
    database: sqlite3.Connection,
    *,
    owner_id: str,
    project_id: str,
    grant_id: str,
    value: Mapping[str, Any],
    current_time: int,
) -> tuple[int, dict[str, Any]]:
    """Persist one owner-authenticated grant revision or revocation marker."""
    grant_id = _service_identifier(grant_id, "grant_id")
    payload_value = _grant_setting_value(value, grant_id, project_id, owner_id)
    expected = value.get("expected_version")
    if isinstance(expected, bool) or not isinstance(expected, int) or expected < 0:
        raise EngagementServiceError(400, "invalid_request", "expected_version is invalid")
    setting_kind = f"engagement-grant:{grant_id}"
    database.execute("BEGIN IMMEDIATE")
    try:
        existing = database.execute(
            "SELECT version FROM service_settings WHERE project_id=? AND setting_kind=?",
            (project_id, setting_kind),
        ).fetchone()
        current = int(existing["version"]) if existing else 0
        if current != expected:
            raise EngagementServiceError(409, "stale_version", "engagement grant version is stale")
        changed = current + 1
        payload = json.dumps(payload_value, sort_keys=True, separators=(",", ":"))
        database.execute(
            "INSERT INTO service_settings VALUES(?,?,?,?,?) ON CONFLICT(project_id,setting_kind) DO UPDATE SET version=excluded.version,value_json=excluded.value_json,updated_at=excluded.updated_at",
            (project_id, setting_kind, changed, payload, current_time),
        )
        database.execute(
            "INSERT INTO audit(credential_id,action,occurred_at,detail) VALUES(?,?,?,?)",
            (
                owner_id,
                "engagement_grant_changed",
                current_time,
                json.dumps({"project_id": project_id, "grant_id": grant_id, "version": changed}),
            ),
        )
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    return 200, {
        "project_id": project_id,
        "grant_id": grant_id,
        "version": changed,
        "state": payload_value["state"],
    }


def evaluate_service_grant(
    database: sqlite3.Connection,
    *,
    method: str,
    path: str,
    value: Mapping[str, Any],
    allowed_projects: frozenset[str],
    permissions: frozenset[str],
) -> dict[str, Any]:
    """Return a content-free eligibility decision for a scoped executor."""
    parts = [part for part in path.split("/") if part]
    route = parts[:3] == ["v1", "executor", "projects"] and parts[4:] == ["engagement", "evaluate"]
    if len(parts) != 6 or not route:
        raise EngagementServiceError(404, "not_found", "resource not found")
    project_id = parts[3]
    if project_id not in allowed_projects or "engagement.execute" not in permissions:
        raise EngagementServiceError(404, "not_found", "resource not found")
    if method != "POST":
        raise EngagementServiceError(405, "method_not_allowed", "executor route accepts only POST")
    _exact_service_fields(value, {"grant_id", "operation_id"})
    grant_id, operation_id = value.get("grant_id"), value.get("operation_id")
    if not isinstance(grant_id, str) or not isinstance(operation_id, str):
        raise EngagementServiceError(400, "invalid_parameter", "grant_id and operation_id are required")
    row = database.execute(
        "SELECT version,value_json FROM service_settings WHERE project_id=? AND setting_kind=?",
        (project_id, f"engagement-grant:{grant_id}"),
    ).fetchone()
    setting = json.loads(row["value_json"]) if row else {}
    if not row or setting.get("state") != "active":
        raise EngagementServiceError(409, "grant_unavailable", "engagement grant is unavailable")
    return {
        "project_id": project_id,
        "operation_id": operation_id,
        "grant_id": grant_id,
        "grant_version": int(row["version"]),
        "policy_hash": setting["policy_hash"],
        "status": "eligible_for_private_outbox_evaluation",
    }
