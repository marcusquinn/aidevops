#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Official-SDK read-only MCP adapter for the local prospecting REST API."""

from __future__ import annotations

import json
import os
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen


class MCPAdapterError(RuntimeError):
    """Raised when the local read API cannot satisfy an MCP tool call."""


class APIClient:
    def __init__(self, base_url: str, authorization: str) -> None:
        parsed = urlsplit(base_url)
        if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "::1", "localhost"} or parsed.username or parsed.password:
            raise MCPAdapterError("MCP API base must be an unauthenticated loopback HTTP URL")
        if not authorization.startswith("Bearer "):
            raise MCPAdapterError("AIDEVOPS_PROSPECTING_AUTH must contain a Bearer credential")
        self.base_url = base_url.rstrip("/")
        self.authorization = authorization

    def get(self, path: str, query: dict[str, Any] | None = None) -> dict[str, Any]:
        target = self.base_url + path
        if query:
            filtered = {key: value for key, value in query.items() if value is not None}
            target += "?" + urlencode(filtered)
        request = Request(target, headers={"Authorization": self.authorization, "Accept": "application/json"})
        try:
            with urlopen(request, timeout=10) as response:  # noqa: S310 -- loopback URL is validated above
                value = json.load(response)
        except HTTPError as error:
            raise MCPAdapterError(f"prospecting API returned HTTP {error.code}") from error
        except (URLError, TimeoutError, json.JSONDecodeError) as error:
            raise MCPAdapterError("prospecting API is unavailable") from error
        if not isinstance(value, dict):
            raise MCPAdapterError("prospecting API returned an invalid document")
        return value


def default_client() -> APIClient:
    return APIClient(
        os.environ.get("AIDEVOPS_PROSPECTING_API", "http://127.0.0.1:8765"),
        os.environ.get("AIDEVOPS_PROSPECTING_AUTH", ""),
    )


def build_server(client: APIClient | None = None):
    try:
        from mcp.server.fastmcp import FastMCP
        from mcp.types import ToolAnnotations
    except ImportError as error:
        raise MCPAdapterError("install the pinned optional mcp dependency before running this adapter") from error

    api = client or default_client()
    server = FastMCP("aidevops-prospecting", instructions="Read-only access to explicitly scoped local prospecting projections.")
    read_only = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)

    @server.tool(annotations=read_only)
    def list_projects() -> dict[str, Any]:
        """List only projects included in the configured read credential."""
        return api.get("/v1/projects")

    @server.tool(annotations=read_only)
    def get_project(project_id: str) -> dict[str, Any]:
        """Get one scoped project's non-secret profile and discovery versions."""
        return api.get(f"/v1/projects/{project_id}")

    @server.tool(annotations=read_only)
    def list_leads(project_id: str, limit: int = 25, cursor: str | None = None,
                   disposition: str | None = None, provider: str | None = None,
                   minimum_score: float = 0) -> dict[str, Any]:
        """List a stable score-ordered page of evidence-linked leads."""
        return api.get(f"/v1/projects/{project_id}/leads", {"limit": limit, "cursor": cursor, "disposition": disposition, "provider": provider, "minimum_score": minimum_score})

    @server.tool(annotations=read_only)
    def get_lead(project_id: str, lead_id: str) -> dict[str, Any]:
        """Get one evidence-linked lead without retrieving raw source content."""
        return api.get(f"/v1/projects/{project_id}/leads/{lead_id}")

    @server.tool(annotations=read_only)
    def get_reddit_seo(project_id: str) -> dict[str, Any]:
        """Get stored Reddit evidence observations and explicit ranking coverage."""
        return api.get(f"/v1/projects/{project_id}/seo")

    @server.tool(annotations=read_only)
    def get_insights(project_id: str) -> dict[str, Any]:
        """Get bounded competitor and intent-theme projections with coverage."""
        return api.get(f"/v1/projects/{project_id}/insights")

    @server.tool(annotations=read_only)
    def get_activity(project_id: str) -> dict[str, Any]:
        """Get bounded local disposition and job activity."""
        return api.get(f"/v1/projects/{project_id}/activity")

    @server.tool(annotations=read_only)
    def get_usage(project_id: str) -> dict[str, Any]:
        """Get recorded usage and cost metadata without starting work."""
        return api.get(f"/v1/projects/{project_id}/usage")

    return server


def main() -> int:
    build_server().run(transport="stdio")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
