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

    def redirect_request(self, *_args: Any) -> None:
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


def _valid_runtime(details: dict[str, Any]) -> bool:
    runtime = details.get("runtime")
    return isinstance(runtime, str) and bool(re.fullmatch(r"[a-z][a-z0-9_-]{0,63}", runtime))


def _valid_hostname(hostname: str) -> bool:
    label_pattern = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
    return len(hostname) <= 253 and all(
        re.fullmatch(label_pattern, label, re.ASCII) for label in hostname.split(".")
    )


def _valid_url(url: Any) -> bool:
    if not isinstance(url, str) or any(char.isspace() or ord(char) < 32 for char in url):
        return False
    parsed = urlsplit(url)
    hostname = parsed.hostname
    simple = (parsed.scheme == "https", bool(hostname), parsed.username is None,
              parsed.password is None, not parsed.query, not parsed.fragment)
    # Accessing port validates malformed/out-of-range ports without contacting the URL.
    return all(simple) and _valid_hostname(hostname or "") and parsed.port in (None, 443)


def _valid_env(details: dict[str, Any]) -> bool:
    if "envSpecificDetails" not in details:
        return True
    config = details["envSpecificDetails"]
    keys = ("buildCommand", "startCommand", "dockerCommand", "dockerContext", "dockerfilePath")
    return isinstance(config, dict) and all(isinstance(config[key], str) for key in keys if key in config)


def _valid_config(payload: dict[str, Any]) -> bool:
    """Minimum serviceDetails contract, not application/deployment validation."""
    details = payload.get("serviceDetails")
    return (isinstance(details, dict) and _valid_runtime(details)
            and _valid_url(details.get("url")) and _valid_env(details))


def _token_problem(token: str | None) -> str | None:
    if not token:
        return "missing_token"
    if len(token) > 4096 or any(ord(char) < 33 or ord(char) > 126 for char in token):
        return "invalid_token"
    return None


def _classify(body: bytes, target: str, evidence: dict[str, str]) -> str:
    if len(body) > MAX_RESPONSE_BYTES:
        return "response_too_large"
    payload = json.loads(body.decode("utf-8"), object_pairs_hook=_unique_object,
                         parse_constant=_invalid_constant)
    if not isinstance(payload, dict):
        return "invalid_response"
    if payload.get("id") != target:
        return "target_mismatch"
    if not _valid_config(payload):
        return "invalid_service_config"
    evidence.update(dict.fromkeys(evidence, "true"))
    return "ready"


def _http_reason(code: int) -> str:
    known = {401: "unauthenticated", 403: "forbidden", 404: "service_not_found", 429: "rate_limited"}
    return known.get(code, "redirect_rejected" if 300 <= code < 400 else "http_error")


def _fetch_reason(target: str, token: str, evidence: dict[str, str]) -> str:
    request = Request(f"https://api.render.com/v1/services/{target}", method="GET",
                      headers={"Authorization": f"Bearer {token}", "Accept": "application/json"})
    try:
        # No environment-selected proxy, arbitrary endpoint, retries, or redirects.
        opener = build_opener(ProxyHandler({}), RejectRedirects())
        with opener.open(request, timeout=TIMEOUT_SECONDS) as response:
            evidence["reachable"] = "true"
            status = response.status
            body = response.read(MAX_RESPONSE_BYTES + 1) if status == 200 else b""
        reason = "unexpected_status" if status != 200 else _classify(body, target, evidence)
    except HTTPError as error:
        evidence["reachable"] = "true"
        reason = _http_reason(error.code)
        error.close()
    except (URLError, OSError, HTTPException):
        reason = "network_error"
    except (ValueError, UnicodeError, RecursionError):
        reason = "invalid_response"
    return reason


def render_live_evidence(
    target: str | None, operation: str, runtime: str, fixture: bool = False,
) -> tuple[dict[str, str], dict[str, Any]]:
    """Return finite, sanitized evidence; never return provider data or exceptions."""
    validate_scope(target, operation, runtime, fixture)
    evidence = dict.fromkeys(("configured", "authenticated", "authorized", "reachable", "usable"), "false")
    scope = {"provider": "render", "target": target, "operation": "read",
             "resource": "service-metadata", "reason": "missing_token"}
    token = os.environ.get("RENDER_API_KEY")
    problem = _token_problem(token)
    if problem is None and token and target:
        evidence["configured"] = "true"
        problem = _fetch_reason(target, token, evidence)
    scope["reason"] = problem
    return evidence, scope
