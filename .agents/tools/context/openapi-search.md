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

# OpenAPI Search MCP

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Navigate any API's OpenAPI spec without loading full docs into context
- **Install**: Zero install — remote Cloudflare Worker at `https://openapi-mcp.openapisearch.com/mcp`
- **Auth**: None required
- **Backend**: `https://search.apis.guru/v1` (override via `OPENAPI_SEARCH_URL`)
- **Workflow**: `searchAPIs` → `getAPIOverview` → `getOperationDetails`
- **Enabled for**: `@openapi-search` subagent only (lazy-loaded — zero install overhead)
- **Docs**: <https://github.com/janwilmake/openapi-mcp-server> | **Directory**: <https://openapisearch.com/search>
- **Verification**: _"Use openapi-search to get an overview of the Stripe API, then show the endpoint for creating a payment intent."_

<!-- AI-CONTEXT-END -->

## Tools

| Step | Tool | Parameters | Returns |
|------|------|------------|---------|
| 0 | `searchAPIs` | `query` (required), `limit` (default 5, max 20) | `apiId`, name, description, relevance score |
| 1 | `getAPIOverview` | `apiId` — identifier or raw OpenAPI URL | Endpoint list, base URL, auth info |
| 2 | `getOperationDetails` | `apiId`, `operationId` (e.g. `"POST /mail/send"`) | Parameters, request/response schemas |

## Configuration

aidevops configures all clients automatically via `setup.sh` / `generate-opencode-agents.sh`. Manual setup:

```bash
claude mcp add --scope user openapi-search --transport http https://openapi-mcp.openapisearch.com/mcp
```

| Client | Config file | Key field |
|--------|-------------|-----------|
| OpenCode | `~/.config/opencode/opencode.json` | `mcp.openapi-search` — `type: remote`, `url`, `enabled: false` |
| Claude Code | `~/.claude/settings.json` | `mcpServers.openapi-search` — `type: http`, `url` |
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` | `mcpServers.openapi-search` — `type: http`, `url` |
| Cursor | `~/.cursor/mcp.json` | `mcpServers.openapi-search.url` |
| Windsurf | `~/.codeium/windsurf/mcp_config.json` | `mcpServers.openapi-search.url` |
| Gemini CLI | `~/.gemini/settings.json` | `mcpServers.openapi-search.url` |
| Continue.dev | `~/.continue/config.json` | `mcpServers[].transport` — `type: sse`, `url` |
| GitHub Copilot | `.vscode/mcp.json` | `servers.openapi-search` — `type: http`, `url` |
| Kilo Code / Kiro | global MCP config | `mcpServers.openapi-search.url` (unverified — no official docs) |
| Zed | `~/.config/zed/settings.json` | `context_servers.openapi-search.url` |

## Usage

```text
# 1. Find APIs for a use case
searchAPIs(query: "convert currency exchange rates")
# → [{ apiId: "exchangerate-api", ... }, { apiId: "fixer.io", ... }]

# 2. Explore the best match
getAPIOverview(apiId: "exchangerate-api")
# → endpoints list, base URL, auth info

# 3. Get details for the specific operation
getOperationDetails(apiId: "exchangerate-api", operationId: "GET /latest/{base}")
# → parameters, response schema, example responses
```

**Use**: unknown API for a task; exploring endpoints before writing integration code; request/response schemas for code generation; comparing APIs.

**Don't use**: you already have the docs (use Context7 or direct docs); testing live calls (read-only); internal/private APIs (indexes public specs only).

## Troubleshooting

**MCP not responding** — check connectivity:

```bash
curl -sf --max-time 10 https://openapi-mcp.openapisearch.com/mcp | head -5
```

**API identifier not found** — browse <https://openapisearch.com/search> or pass a direct URL to a raw OpenAPI file.

**Spec too large** — some large APIs (e.g., AWS) exceed the 250K character limit. Use a more specific sub-spec URL.
