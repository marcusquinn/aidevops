#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Official-SDK read-only MCP adapter for the local prospecting REST API."""

from __future__ import annotations

import json
import os
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


class MCPAdapterError(RuntimeError):
    """Raised when the local read API cannot satisfy an MCP tool call."""


class _RejectRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_arguments, **_keywords):  # noqa: ANN002,ANN003,ANN201
        return None


class APIClient:
    def __init__(self, base_url: str, authorization: str) -> None:
        parsed = urlsplit(base_url)
        if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "::1", "localhost"} or parsed.username or parsed.password:
            raise MCPAdapterError("MCP API base must be an unauthenticated loopback HTTP URL")
        if not authorization.startswith("Bearer "):
            raise MCPAdapterError("AIDEVOPS_PROSPECTING_AUTH must contain a Bearer credential")
        self.base_url = base_url.rstrip("/")
        self.authorization = authorization
        self.opener = build_opener(_RejectRedirect())

    def get(self, path: str, query: dict[str, Any] | None = None) -> dict[str, Any]:
        target = self.base_url + path
        if query:
            filtered = {key: value for key, value in query.items() if value is not None}
            target += "?" + urlencode(filtered)
        request = Request(target, headers={"Authorization": self.authorization, "Accept": "application/json"})
        try:
            with self.opener.open(request, timeout=10) as response:
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


class ProspectingTools:
    """Read-only MCP methods backed by one scoped local API client."""

    def __init__(self, client: APIClient) -> None:
        self.client = client

    @staticmethod
    def _segment(value: str) -> str:
        return quote(value, safe="")

    def list_projects(self) -> dict[str, Any]:
        """List only projects included in the configured read credential."""
        return self.client.get("/v1/projects")

    def get_project(self, project_id: str) -> dict[str, Any]:
        """Get one scoped project's non-secret profile and discovery versions."""
        return self.client.get(f"/v1/projects/{self._segment(project_id)}")

    def list_leads(self, project_id: str, filters: dict[str, Any] | None = None) -> dict[str, Any]:
        """List a stable score-ordered page of evidence-linked leads."""
        query = filters or {}
        allowed = {"limit", "cursor", "disposition", "provider", "minimum_score"}
        if set(query) - allowed:
            raise MCPAdapterError("lead filters contain unsupported fields")
        return self.client.get(f"/v1/projects/{self._segment(project_id)}/leads", query)

    def get_lead(self, project_id: str, lead_id: str) -> dict[str, Any]:
        """Get one evidence-linked lead without retrieving raw source content."""
        return self.client.get(f"/v1/projects/{self._segment(project_id)}/leads/{self._segment(lead_id)}")

    def get_reddit_seo(self, project_id: str) -> dict[str, Any]:
        """Get stored Reddit evidence observations and explicit ranking coverage."""
        return self.client.get(f"/v1/projects/{self._segment(project_id)}/seo")

    def get_insights(self, project_id: str) -> dict[str, Any]:
        """Get bounded competitor and intent-theme projections with coverage."""
        return self.client.get(f"/v1/projects/{self._segment(project_id)}/insights")

    def get_activity(self, project_id: str) -> dict[str, Any]:
        """Get bounded local disposition and job activity."""
        return self.client.get(f"/v1/projects/{self._segment(project_id)}/activity")

    def get_usage(self, project_id: str) -> dict[str, Any]:
        """Get recorded usage and cost metadata without starting work."""
        return self.client.get(f"/v1/projects/{self._segment(project_id)}/usage")


def build_server(client: APIClient | None = None):
    try:
        from mcp.server.fastmcp import FastMCP
        from mcp.types import ToolAnnotations
    except ImportError as error:
        raise MCPAdapterError("install the pinned optional mcp dependency before running this adapter") from error

    server = FastMCP("aidevops-prospecting", instructions="Read-only access to explicitly scoped local prospecting projections.")
    read_only = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)
    tools = ProspectingTools(client or default_client())
    for name in ("list_projects", "get_project", "list_leads", "get_lead",
                 "get_reddit_seo", "get_insights", "get_activity", "get_usage"):
        server.tool(name=name, annotations=read_only)(getattr(tools, name))
    return server


def main() -> int:
    build_server().run(transport="stdio")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
