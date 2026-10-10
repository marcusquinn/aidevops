# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""HTTP, pagination and tool lookup helpers for Codacy coding standards."""

import json
import os
import urllib.error
import urllib.parse
import urllib.request

API = os.environ.get("CODACY_API_URL", "https://app.codacy.com/api/v3")
PROVIDER = "gh"
PAGE_LIMIT = 1000


class CodacyError(Exception):
    """API or procedure failure."""


def token():
    value = os.environ.get("CODACY_API_TOKEN", "")
    if not value:
        raise SystemExit("CODACY_API_TOKEN is not set (use: aidevops secret CODACY_API_TOKEN -- ...)")
    return value


def call(method, path, body=None, params=None):
    """Return decoded JSON (or None for empty bodies)."""
    url = API + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("api-token", token())
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:300]
        raise CodacyError(f"{method} {path} -> HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise CodacyError(f"{method} {path} failed: {exc.reason}") from exc
    return json.loads(raw) if raw.strip() else None


def paged(path, params=None):
    """Collect `data` across pagination.cursor pages."""
    items = []
    query = dict(params or {})
    query.setdefault("limit", PAGE_LIMIT)
    while True:
        page = call("GET", path, params=query) or {}
        items.extend(page.get("data", []))
        cursor = (page.get("pagination") or {}).get("cursor")
        if not cursor:
            return items
        query["cursor"] = cursor


def org_base(org):
    return f"/organizations/{PROVIDER}/{urllib.parse.quote(org)}"


def organizations():
    return [o["name"] for o in paged("/user/organizations")]


def standards(org):
    return paged(org_base(org) + "/coding-standards")


def standard_tools(org, std_id):
    return paged(f"{org_base(org)}/coding-standards/{std_id}/tools")


def tool_enabled(tool):
    for key in ("isEnabled", "enabled"):
        if key in tool:
            return bool(tool[key])
    return False


def tool_uuid(tool):
    return tool.get("uuid") or tool.get("id")


def resolve_tool(tools, ref):
    """Match a tool by UUID or case-insensitive name."""
    wanted = ref.lower()
    for tool in tools:
        name = str(tool.get("name", "")).lower()
        if str(tool_uuid(tool)).lower() == wanted or name == wanted:
            return tool
    raise CodacyError(f"tool not found in standard: {ref}")
