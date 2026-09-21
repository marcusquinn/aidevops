#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Typed REST projections and owner-only controls for prospecting data."""

from __future__ import annotations

import base64
import json
import sqlite3
import time
from collections import defaultdict, deque
from dataclasses import dataclass
from http.cookies import SimpleCookie
from typing import Any, Mapping
from urllib.parse import parse_qs, urlsplit

import prospecting_auth
import prospecting_jobs
from _public_engagement_policy import (
    EngagementServiceError,
    ServiceGrantEvaluation,
    evaluate_service_grant,
)
from prospecting_contract import ContractError
from prospecting_store import (
    ProspectingStoreError,
    StaleVersionError,
    export_project,
    list_leads,
)

API_SCHEMA = "aidevops.prospecting-api/v1"
MAX_BODY = 65_536
MAX_RESPONSE = 1_048_576
MAX_PAGE = 100
SAFE_HOSTS = frozenset({"127.0.0.1", "localhost", "[::1]"})


class APIError(ValueError):
    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


@dataclass(frozen=True)
class Response:
    status: int
    body: dict[str, Any]
    headers: Mapping[str, str]


@dataclass(frozen=True)
class OriginPolicy:
    bind_host: str = "127.0.0.1"
    public_host: str | None = None
    scheme: str = "http"


class RateLimiter:
    def __init__(self, maximum: int = 120, window_seconds: int = 60) -> None:
        self.maximum, self.window_seconds = maximum, window_seconds
        self.events: dict[str, deque[float]] = defaultdict(deque)

    def check(self, identity: str) -> None:
        now = time.monotonic()
        events = self.events[identity]
        while events and events[0] <= now - self.window_seconds:
            events.popleft()
        if len(events) >= self.maximum:
            raise APIError(429, "rate_limited", "request rate exceeded")
        events.append(now)


def _json_body(raw: bytes) -> dict[str, Any]:
    if len(raw) > MAX_BODY:
        raise APIError(413, "body_too_large", "request body exceeds limit")
    try:
        value = json.loads(raw or b"{}")
    except json.JSONDecodeError as error:
        raise APIError(400, "invalid_json", "request body must be JSON") from error
    if not isinstance(value, dict):
        raise APIError(400, "invalid_json", "request body must be an object")
    return value


def _exact(value: Mapping[str, Any], allowed: set[str]) -> None:
    extra = sorted(set(value) - allowed)
    if extra:
        raise APIError(400, "unsupported_fields", "unsupported fields: " + ", ".join(extra))


def _integer(value: str | None, default: int, minimum: int, maximum: int, field: str) -> int:
    try:
        parsed = default if value is None else int(value)
    except (TypeError, ValueError) as error:
        raise APIError(400, "invalid_parameter", f"{field} must be an integer") from error
    if not minimum <= parsed <= maximum:
        raise APIError(400, "invalid_parameter", f"{field} is outside its allowed range")
    return parsed


def _cursor(item: dict[str, Any]) -> str:
    value = json.dumps([item["score"], item["lead_id"]], separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


def _after(cursor: str | None) -> tuple[float, str] | None:
    if cursor is None:
        return None
    try:
        raw = base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4))
        value = json.loads(raw)
    except (ValueError, json.JSONDecodeError) as error:
        raise APIError(400, "invalid_cursor", "cursor is invalid") from error
    if not isinstance(value, list) or len(value) != 2 or not isinstance(value[0], (int, float)) or not isinstance(value[1], str):
        raise APIError(400, "invalid_cursor", "cursor is invalid")
    return float(value[0]), value[1]


def _cookie(headers: Mapping[str, str], name: str) -> str:
    values = SimpleCookie()
    values.load(headers.get("Cookie", ""))
    return getattr(values.get(name), "value", "")


def _project_exists(database: sqlite3.Connection, project_id: str) -> bool:
    return database.execute("SELECT 1 FROM projects WHERE project_id=?", (project_id,)).fetchone() is not None


class ProspectingAPI:
    """Transport-neutral router used by HTTP and focused tests."""

    def __init__(self, database: sqlite3.Connection, auth_database: sqlite3.Connection,
                 origin_policy: OriginPolicy | None = None) -> None:
        self.database, self.auth_database = database, auth_database
        policy = origin_policy or OriginPolicy()
        self.allowed_hosts = SAFE_HOSTS if policy.bind_host in SAFE_HOSTS else frozenset({policy.public_host or ""})
        self.scheme = policy.scheme
        self.rate_limiter = RateLimiter()

    def request(self, method: str, target: str, headers: Mapping[str, str] | None = None, body: bytes = b"") -> Response:
        headers = headers or {}
        try:
            response = self._dispatch(method.upper(), target, headers, body)
        except (APIError, prospecting_auth.OperatorError, EngagementServiceError) as error:
            response = Response(error.status, {"schema": API_SCHEMA, "error": {"code": error.code, "message": error.message}}, {})
        except (ContractError, ProspectingStoreError, StaleVersionError, prospecting_jobs.RoutineError) as error:
            response = Response(409, {"schema": API_SCHEMA, "error": {"code": "conflict", "message": str(error)}}, {})
        except sqlite3.Error:
            response = Response(503, {"schema": API_SCHEMA, "error": {"code": "unavailable", "message": "prospecting store is unavailable"}}, {})
        encoded = json.dumps(response.body, separators=(",", ":")).encode()
        if len(encoded) > MAX_RESPONSE:
            return Response(507, {"schema": API_SCHEMA, "error": {"code": "response_too_large", "message": "response exceeds limit"}}, self._headers({}))
        return Response(response.status, response.body, self._headers(response.headers))

    def _headers(self, extra: Mapping[str, str]) -> dict[str, str]:
        return {
            "Content-Type": "application/json; charset=utf-8",
            "Cache-Control": "no-store",
            "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'",
            "X-Content-Type-Options": "nosniff",
            **extra,
        }

    def _read_principal(self, headers: Mapping[str, str]) -> prospecting_auth.Principal:
        try:
            principal = prospecting_auth.authenticate_read(self.auth_database, headers.get("Authorization", ""))
        except prospecting_auth.AuthError as error:
            raise APIError(401, "unauthorized", "authentication required") from error
        self.rate_limiter.check(principal.credential_id)
        return principal

    def _owner_principal(self, headers: Mapping[str, str]) -> prospecting_auth.Principal:
        host_header = headers.get("Host", "")
        try:
            host = urlsplit("//" + host_header).hostname
        except ValueError as error:
            raise APIError(403, "origin_denied", "owner request origin is not allowed") from error
        origin = headers.get("Origin", "")
        allowed_origin = f"{self.scheme}://{host_header}"
        if host not in self.allowed_hosts or origin != allowed_origin:
            raise APIError(403, "origin_denied", "owner request origin is not allowed")
        try:
            principal = prospecting_auth.authenticate_owner(
                self.auth_database, _cookie(headers, "prospecting_owner"), headers.get("X-CSRF-Token", "")
            )
        except prospecting_auth.AuthError as error:
            raise APIError(401, "unauthorized", "owner authentication required") from error
        self.rate_limiter.check(principal.credential_id)
        return principal

    def _executor_principal(self, headers: Mapping[str, str]) -> prospecting_auth.Principal:
        try:
            principal = prospecting_auth.authenticate_engagement_executor(
                self.auth_database, headers.get("Authorization", "")
            )
        except prospecting_auth.AuthError as error:
            raise APIError(401, "unauthorized", "engagement executor authentication required") from error
        self.rate_limiter.check(principal.credential_id)
        return principal

    @staticmethod
    def _authorize(principal: prospecting_auth.Principal, project_id: str, permission: str = "read") -> None:
        if not principal.allows(project_id, permission):
            raise APIError(404, "not_found", "resource not found")

    def _dispatch(self, method: str, target: str, headers: Mapping[str, str], body: bytes) -> Response:
        parsed = urlsplit(target)
        path = parsed.path
        query = {key: values[-1] for key, values in parse_qs(parsed.query, keep_blank_values=True).items()}
        if method == "GET" and path == "/v1/health":
            return Response(200, {"schema": API_SCHEMA, "status": "ok", "api_version": 1}, {})
        if path.startswith("/v1/operator/"):
            return self._operator(method, path, headers, body)
        if path.startswith("/v1/executor/"):
            return self._engagement_executor(method, path, headers, body)
        principal = self._read_principal(headers)
        if method == "GET" and path == "/v1/projects":
            return self._projects(principal)
        return self._project_read(method, path, query, principal)

    def _project_read(self, method: str, path: str, query: Mapping[str, str],
                      principal: prospecting_auth.Principal) -> Response:
        parts = [part for part in path.split("/") if part]
        if len(parts) < 3 or parts[:2] != ["v1", "projects"]:
            raise APIError(404, "not_found", "resource not found")
        project_id = parts[2]
        self._authorize(principal, project_id)
        if not _project_exists(self.database, project_id):
            raise APIError(404, "not_found", "resource not found")
        if method != "GET":
            raise APIError(405, "method_not_allowed", "read credentials cannot mutate data")
        if len(parts) == 3:
            return Response(200, self._project_detail(project_id), {})
        if parts[3] == "leads":
            return self._lead_read(project_id, parts, query)
        handlers = {"seo": self._seo, "insights": self._insights,
                    "activity": self._activity, "usage": self._usage}
        if len(parts) != 4 or parts[3] not in handlers:
            raise APIError(404, "not_found", "resource not found")
        return Response(200, handlers[parts[3]](project_id), {})

    def _lead_read(self, project_id: str, parts: list[str], query: Mapping[str, str]) -> Response:
        if len(parts) == 4:
            body = self._leads(project_id, query)
        elif len(parts) == 5:
            body = self._lead(project_id, parts[4])
        else:
            raise APIError(404, "not_found", "resource not found")
        return Response(200, body, {})

    def _projects(self, principal: prospecting_auth.Principal) -> Response:
        query = "SELECT project_id,name,profile_version,discovery_version,updated_at FROM projects WHERE project_id=?"
        rows = filter(None, (self.database.execute(query, (project_id,)).fetchone()
                             for project_id in sorted(principal.projects)))
        scoped = [dict(row) for row in rows]
        return Response(200, {"schema": API_SCHEMA, "as_of": int(time.time()), "projects": scoped}, {})

    def _project_detail(self, project_id: str) -> dict[str, Any]:
        value = export_project(self.database, project_id)["project"]
        value["profile"] = {key: item for key, item in value["profile"].items() if key != "secret_profile_refs"}
        return {"schema": API_SCHEMA, "as_of": int(time.time()), "project": value}

    def _leads(self, project_id: str, query: Mapping[str, str]) -> dict[str, Any]:
        _exact(query, {"limit", "cursor", "disposition", "provider", "minimum_score"})
        limit = _integer(query.get("limit"), 25, 1, MAX_PAGE, "limit")
        disposition, provider = query.get("disposition"), query.get("provider")
        try:
            minimum_score = float(query.get("minimum_score", "0"))
        except ValueError as error:
            raise APIError(400, "invalid_parameter", "minimum_score must be numeric") from error
        if not 0 <= minimum_score <= 100:
            raise APIError(400, "invalid_parameter", "minimum_score is outside its allowed range")
        rows = [row for row in list_leads(self.database, project_id, disposition=disposition, limit=1000)
                if row["score"] >= minimum_score and (provider is None or row["provider"] == provider)]
        after = _after(query.get("cursor"))
        if after:
            rows = [row for row in rows if (-float(row["score"]), row["lead_id"]) > (-after[0], after[1])]
        page = rows[:limit]
        return {"schema": API_SCHEMA, "as_of": int(time.time()), "project_id": project_id,
                "items": page, "next_cursor": _cursor(page[-1]) if len(rows) > limit else None,
                "coverage": {"returned": len(page), "available_after_filters": len(rows)}}

    def _lead(self, project_id: str, lead_id: str) -> dict[str, Any]:
        rows = [row for row in list_leads(self.database, project_id, limit=1000) if row["lead_id"] == lead_id]
        if not rows:
            raise APIError(404, "not_found", "resource not found")
        return {"schema": API_SCHEMA, "as_of": int(time.time()), "project_id": project_id, "lead": rows[0]}

    def _seo(self, project_id: str) -> dict[str, Any]:
        rows = self.database.execute(
            "SELECT evidence_id,object_id,object_type,observed_at FROM evidence_objects WHERE project_id=? AND provider='reddit' ORDER BY observed_at DESC,object_id",
            (project_id,),
        ).fetchall()
        return {"schema": API_SCHEMA, "project_id": project_id, "as_of": int(time.time()),
                "authority": "stored_reddit_evidence_observations", "observations": [dict(row) for row in rows],
                "coverage": {"observation_count": len(rows), "ranking": "not_available_without_serp_snapshot"}}

    def _insights(self, project_id: str) -> dict[str, Any]:
        exported = export_project(self.database, project_id)
        leads = exported["leads"]
        competitors = exported["project"]["profile"].get("competitors", [])
        themes: dict[str, int] = defaultdict(int)
        for lead in leads:
            themes[lead["intent"]] += 1
        return {"schema": API_SCHEMA, "project_id": project_id, "as_of": int(time.time()),
                "authority": "bounded_project_read_model", "competitors": competitors,
                "themes": [{"theme": key, "lead_count": value} for key, value in sorted(themes.items())],
                "coverage": {"lead_count": len(leads), "full_source_content": False}}

    def _activity(self, project_id: str) -> dict[str, Any]:
        dispositions = self.database.execute(
            "SELECT lead_id,disposition,version,changed_at FROM disposition_history WHERE project_id=? ORDER BY event_id DESC LIMIT 100",
            (project_id,),
        ).fetchall()
        jobs = self.database.execute(
            "SELECT job_id,job_kind,status,started_at,finished_at FROM jobs WHERE project_id=? ORDER BY COALESCE(started_at,'') DESC,job_id LIMIT 100",
            (project_id,),
        ).fetchall()
        return {"schema": API_SCHEMA, "project_id": project_id, "as_of": int(time.time()),
                "dispositions": [dict(row) for row in dispositions], "jobs": [dict(row) for row in jobs]}

    def _usage(self, project_id: str) -> dict[str, Any]:
        rows = self.database.execute(
            "SELECT usage_id,job_id,provider,unit,quantity,cost_amount,currency,recorded_at FROM usage_records WHERE project_id=? ORDER BY recorded_at DESC,usage_id LIMIT 500",
            (project_id,),
        ).fetchall()
        return {"schema": API_SCHEMA, "project_id": project_id, "as_of": int(time.time()),
                "records": [dict(row) for row in rows], "coverage": {"record_count": len(rows), "limit": 500}}

    def _operator(self, method: str, path: str, headers: Mapping[str, str], raw: bytes) -> Response:
        principal = self._owner_principal(headers)
        value = _json_body(raw)
        parts = [part for part in path.split("/") if part]
        status, result = prospecting_auth.OperatorContext(
            self.database, self.auth_database, principal
        ).execute(method, parts, value)
        return Response(status, {"schema": API_SCHEMA, **result}, {})

    def _engagement_executor(
        self, method: str, path: str, headers: Mapping[str, str], raw: bytes
    ) -> Response:
        """Expose only content-free grant selection to scoped executors."""
        principal = self._executor_principal(headers)
        result = evaluate_service_grant(
            self.auth_database,
            ServiceGrantEvaluation(
                method=method,
                path=path,
                value=_json_body(raw),
                allowed_projects=principal.projects,
                permissions=principal.permissions,
            ),
        )
        return Response(202, {
            "schema": API_SCHEMA,
            **result,
        }, {})
