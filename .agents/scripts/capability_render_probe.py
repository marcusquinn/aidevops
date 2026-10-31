"""Bounded, exact-service, GET-only Render metadata readiness evidence."""

from __future__ import annotations

import json
from http.client import HTTPException
import os
import re
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

TARGET_PATTERN = re.compile(r"srv-[a-z0-9]+", re.ASCII)
TIMEOUT_SECONDS = 10
MAX_RESPONSE_BYTES = 262144
RUNTIMES = {"opencode", "claude-code"}


class RejectRedirects(HTTPRedirectHandler):
    """Never forward the bearer token to a redirect destination."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def validate_scope(target: str | None, operation: str, runtime: str, fixture: bool) -> None:
    """Reject unsupported scopes before credentials, fixture reads, or transport."""
    if fixture:
        raise ValueError("render_fixture_not_allowed")
    if runtime not in RUNTIMES:
        raise ValueError("render_unsupported_runtime")
    if operation != "read":
        raise ValueError("render_read_only")
    if not isinstance(target, str) or not TARGET_PATTERN.fullmatch(target):
        raise ValueError("render_invalid_target")


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_key")
        result[key] = value
    return result


def _invalid_constant(_: str) -> None:
    raise ValueError("invalid_constant")


def _valid_config(payload: dict[str, Any]) -> bool:
    """Minimum serviceDetails contract, not application/deployment validation."""
    details = payload.get("serviceDetails")
    if not isinstance(details, dict):
        return False
    runtime, url = details.get("runtime"), details.get("url")
    if not isinstance(runtime, str) or not re.fullmatch(r"[a-z][a-z0-9_-]{0,63}", runtime):
        return False
    if not isinstance(url, str) or any(char.isspace() or ord(char) < 32 for char in url):
        return False
    parsed = urlsplit(url)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username is not None
            or parsed.password is not None or parsed.query or parsed.fragment):
        return False
    # Accessing port validates malformed/out-of-range ports without contacting the URL.
    if parsed.port not in (None, 443):
        return False
    if "envSpecificDetails" in details:
        config = details["envSpecificDetails"]
        if not isinstance(config, dict):
            return False
        for key in ("buildCommand", "startCommand", "dockerCommand", "dockerContext", "dockerfilePath"):
            if key in config and not isinstance(config[key], str):
                return False
    return True


def render_live_evidence(
    target: str | None, operation: str, runtime: str, fixture: bool = False,
) -> tuple[dict[str, str], dict[str, Any]]:
    """Return finite, sanitized evidence; never return provider data or exceptions."""
    validate_scope(target, operation, runtime, fixture)
    evidence = dict.fromkeys(("configured", "authenticated", "authorized", "reachable", "usable"), "false")
    scope = {"provider": "render", "target": target, "operation": "read",
             "resource": "service-metadata", "reason": "missing_token"}
    token = os.environ.get("RENDER_API_KEY")
    if not token:
        return evidence, scope
    if len(token) > 4096 or any(ord(char) < 33 or ord(char) > 126 for char in token):
        scope["reason"] = "invalid_token"
        return evidence, scope
    evidence["configured"] = "true"
    request = Request(f"https://api.render.com/v1/services/{target}", method="GET",
                      headers={"Authorization": f"Bearer {token}", "Accept": "application/json"})
    try:
        # No environment-selected proxy, arbitrary endpoint, retries, or redirects.
        opener = build_opener(ProxyHandler({}), RejectRedirects())
        with opener.open(request, timeout=TIMEOUT_SECONDS) as response:
            evidence["reachable"] = "true"
            if response.status != 200:
                scope["reason"] = "unexpected_status"
                return evidence, scope
            body = response.read(MAX_RESPONSE_BYTES + 1)
        if len(body) > MAX_RESPONSE_BYTES:
            scope["reason"] = "response_too_large"
            return evidence, scope
        payload = json.loads(body.decode("utf-8"), object_pairs_hook=_unique_object,
                             parse_constant=_invalid_constant)
        if not isinstance(payload, dict):
            scope["reason"] = "invalid_response"
        elif payload.get("id") != target:
            scope["reason"] = "target_mismatch"
        elif not _valid_config(payload):
            scope["reason"] = "invalid_service_config"
        else:
            evidence.update(dict.fromkeys(evidence, "true"))
            scope["reason"] = "ready"
    except HTTPError as error:
        evidence["reachable"] = "true"
        scope["reason"] = {401: "unauthenticated", 403: "forbidden", 404: "service_not_found",
                           429: "rate_limited"}.get(error.code, "redirect_rejected" if 300 <= error.code < 400 else "http_error")
        error.close()
    except (URLError, OSError, HTTPException):
        scope["reason"] = "network_error"
    except (ValueError, UnicodeError, RecursionError):
        scope["reason"] = "invalid_response"
    return evidence, scope
