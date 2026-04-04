---
description: OpenAPI Search MCP — search and explore any OpenAPI spec via 3-step process
mode: subagent
tools:
  openapi-search_searchAPIs: true
  openapi-search_getAPIOverview: true
  openapi-search_getOperationDetails: true
  read: true
  write: false
  edit: false
  bash: false
  glob: false
  grep: false
  webfetch: true
  task: false
mcp:
  - openapi-search
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# OpenAPI Search MCP

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Navigate any API's OpenAPI spec without loading full docs into context
- **Install**: Zero install — remote Cloudflare Worker, no auth required; backend `https://search.apis.guru/v1` (override via `OPENAPI_SEARCH_URL`)
- **Workflow**: `searchAPIs` → `getAPIOverview` → `getOperationDetails`
- **Enabled for**: `@openapi-search` subagent only (lazy-loaded — zero install overhead)
- **Docs**: <https://github.com/janwilmake/openapi-mcp-server> | **Directory**: <https://openapisearch.com/search>
- **Use when**: unknown API for a task; exploring endpoints; request/response schemas for code generation; comparing APIs
- **Don't use when**: you already have the docs (use Context7); testing live calls (read-only); internal/private APIs (indexes public specs only)
- **Verification**: _"Use openapi-search to get an overview of the Stripe API, then show the endpoint for creating a payment intent."_

<!-- AI-CONTEXT-END -->

## Tools

| Step | Tool | Parameters | Returns |
|------|------|------------|---------|
| 1 | `searchAPIs` | `query` (required), `limit` (default 5, max 20) | `apiId`, name, description, relevance score |
| 2 | `getAPIOverview` | `apiId` — identifier or raw OpenAPI URL | Endpoint list, base URL, auth info |
| 3 | `getOperationDetails` | `apiId`, `operationId` (e.g. `"POST /mail/send"`) | Parameters, request/response schemas |

## Setup

Auto-configured by `setup.sh` / `generate-opencode-agents.sh`. Manual (Claude Code):

```bash
claude mcp add --scope user openapi-search --transport http https://openapi-mcp.openapisearch.com/mcp
```

Other clients: `mcpServers.openapi-search` with `type: http`, `url: https://openapi-mcp.openapisearch.com/mcp`. Exceptions: OpenCode → `type: remote`; Continue.dev → `type: sse`; Zed → `context_servers`.

## Usage

```text
searchAPIs(query: "convert currency exchange rates")
# → [{ apiId: "exchangerate-api", ... }, { apiId: "fixer.io", ... }]

getAPIOverview(apiId: "exchangerate-api")
# → endpoints list, base URL, auth info

getOperationDetails(apiId: "exchangerate-api", operationId: "GET /latest/{base}")
# → parameters, response schema, example responses
```

## Troubleshooting

**MCP not responding** — check connectivity:

```bash
curl -sf --max-time 10 https://openapi-mcp.openapisearch.com/mcp | head -5
```

**API identifier not found** — browse <https://openapisearch.com/search> or pass a direct URL to a raw OpenAPI file.

**Spec too large** — some large APIs (e.g., AWS) exceed the 250K character limit. Use a more specific sub-spec URL.
