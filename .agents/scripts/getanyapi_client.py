#!/usr/bin/env python3
"""Bounded HTTPS and private-input primitives for the GetAnyAPI helper."""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, NamedTuple

from getanyapi_evidence import AnyAPIError

API_BASE = "https://api.getanyapi.com"


class RequestOptions(NamedTuple):
    """Optional request controls kept out of the public call signature."""

    key: str | None = None
    payload: Any = None
    timeout: int = 120
    headers: dict[str, str] | None = None


def parse_json_bytes(raw: bytes) -> Any:
    if not raw:
        return {}
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise AnyAPIError("AnyAPI returned a non-JSON response") from exc


def api_request(
    method: str,
    path: str,
    options: RequestOptions | None = None,
) -> tuple[int, Any, dict[str, str]]:
    options = options or RequestOptions()
    request_headers = {"Accept": "application/json", **(options.headers or {})}
    if options.key:
        request_headers["Authorization"] = f"Bearer {options.key}"
    data = None
    if options.payload is not None:
        data = json.dumps(options.payload, separators=(",", ":")).encode("utf-8")
        request_headers["Content-Type"] = "application/json"
    request = urllib.request.Request(
        f"{API_BASE}{path}", data=data, headers=request_headers, method=method
    )
    try:
        with urllib.request.urlopen(request, timeout=options.timeout) as response:
            return (
                response.status,
                parse_json_bytes(response.read()),
                {key.lower(): value for key, value in response.headers.items()},
            )
    except urllib.error.HTTPError as exc:
        body = parse_json_bytes(exc.read())
        raise AnyAPIError(
            f"AnyAPI returned HTTP {exc.code}; response body suppressed",
            exc.code,
            body,
        )
    except urllib.error.URLError as exc:
        raise AnyAPIError(f"AnyAPI request failed: {exc.reason}") from exc


def read_input(path_value: str) -> Any:
    if path_value == "-":
        raw = sys.stdin.read()
    else:
        path = Path(path_value).expanduser()
        if not path.is_file() or path.is_symlink():
            raise AnyAPIError("input file must be a regular, non-symlink file")
        if os.name == "posix" and path.stat().st_mode & 0o077:
            raise AnyAPIError("input file must be owner-only (chmod 600)")
        raw = path.read_text(encoding="utf-8")
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise AnyAPIError(f"input is not valid JSON: {exc.msg}") from exc
    if not isinstance(payload, dict):
        raise AnyAPIError("input JSON must be an object")
    return payload


def query_string(values: dict[str, Any]) -> str:
    filtered = {key: value for key, value in values.items() if value not in (None, "")}
    return urllib.parse.urlencode(filtered)
