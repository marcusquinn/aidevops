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
  openapi-search_*: true
mcp:
  - openapi-search
---

# OpenAPI Search MCP

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Search and explore OpenAPI specifications for any API — lets LLMs understand any API's structure and endpoints
- **Install**: Zero install — remote Cloudflare Worker at `https://openapi-mcp.openapisearch.com/mcp`
- **Auth**: None required
- **Backend**: `https://search.apis.guru/v1` (overridable via `OPENAPI_SEARCH_URL` env var)
- **MCP Tools**:
  - `searchAPIs` — Semantic search for APIs relevant to a use case (step 0)
  - `getAPIOverview` — Get a summary of any API's endpoints (step 1)
  - `getOperationDetails` — Get details about a specific endpoint (step 2)
- **Docs**: <https://github.com/janwilmake/openapi-mcp-server>
- **Directory**: <https://openapisearch.com/search>

**Intended workflow**: `searchAPIs` -> `getAPIOverview` -> `getOperationDetails`

**OpenCode Config**:

```json
"openapi-search": {
  "type": "remote",
  "url": "https://openapi-mcp.openapisearch.com/mcp",
  "enabled": false
}
```

**Verification Prompt**:

```text
Use the openapi-search MCP to get an overview of the Stripe API, then show me the endpoint for creating a payment intent.
```

**Enabled for Agents**: `@openapi-search` subagent only (lazy-loaded — zero install overhead)

**Usage Strategy**: Use when you need to understand an unfamiliar API before writing integration code.
The 3-step process (search → overview → endpoint detail) keeps context usage minimal.

<!-- AI-CONTEXT-END -->

## What It Does

OpenAPI Search MCP lets LLMs navigate complex API specifications without loading entire
OpenAPI documents into context. It uses a 3-step process:

| Step | Tool | Purpose |
|------|------|---------|
| 0 | `searchAPIs(query)` | Find APIs relevant to a use case via semantic search |
| 1 | `getAPIOverview(apiId)` | Get a plain-language summary of all endpoints |
| 2 | `getOperationDetails(apiId, operationId)` | Get full details for a specific endpoint |

The server converts OpenAPI specs (including Swagger 2.x) to simple language, making
even the largest APIs navigable without overwhelming context.

## Prerequisites

- No installation required
- No authentication required
- Works with any MCP-compatible AI assistant

## Configuration

### OpenCode

Add to `~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "openapi-search": {
      "type": "remote",
      "url": "https://openapi-mcp.openapisearch.com/mcp",
      "enabled": false
    }
  }
}
```

> **Note**: aidevops configures this automatically via `setup.sh` / `generate-opencode-agents.sh`.
> The MCP is lazy-loaded (disabled globally, enabled only in the `@openapi-search` subagent).

### Claude Code

```bash
claude mcp add --scope user openapi-search --transport http https://openapi-mcp.openapisearch.com/mcp
```

Or edit `~/.claude/settings.json`:

```json
{
  "mcpServers": {
    "openapi-search": {
      "type": "http",
      "url": "https://openapi-mcp.openapisearch.com/mcp"
    }
  }
}
```

### Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "openapi-search": {
      "type": "http",
      "url": "https://openapi-mcp.openapisearch.com/mcp"
    }
  }
}
```

### With npx (alternative)

```json
{
  "mcpServers": {
    "openapi-search": {
      "command": "npx",
      "args": ["-y", "@openapi-search/mcp-server"]
    }
  }
}
```

### With Bun (faster startup)

```json
{
  "mcpServers": {
    "openapi-search": {
      "command": "bunx",
      "args": ["--bun", "-y", "@openapi-search/mcp-server"]
    }
  }
}
```

### Cursor

Edit `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "openapi-search": {
      "url": "https://openapi-mcp.openapisearch.com/mcp"
    }
  }
}
```

### Windsurf

Edit `~/.codeium/windsurf/mcp_config.json`:

```json
{
  "mcpServers": {
    "openapi-search": {
      "serverUrl": "https://openapi-mcp.openapisearch.com/mcp"
    }
  }
}
```

### Gemini CLI

Edit `~/.gemini/settings.json`:

```json
{
  "mcpServers": {
    "openapi-search": {
      "url": "https://openapi-mcp.openapisearch.com/mcp"
    }
  }
}
```

### Continue.dev

Edit `~/.continue/config.json`:

```json
{
  "mcpServers": [
    {
      "name": "openapi-search",
      "transport": {
        "type": "streamable-http",
        "url": "https://openapi-mcp.openapisearch.com/mcp"
      }
    }
  ]
}
```

### Zed

Add via Zed's MCP server UI (Settings → Extensions → MCP Servers):

- Name: `openapi-search`
- URL: `https://openapi-mcp.openapisearch.com/mcp`

### GitHub Copilot (VS Code)

Add to `.vscode/mcp.json` in your project:

```json
{
  "servers": {
    "openapi-search": {
      "type": "http",
      "url": "https://openapi-mcp.openapisearch.com/mcp"
    }
  }
}
```

### Kilo Code / Kiro

Add to global MCP config:

```json
{
  "mcpServers": {
    "openapi-search": {
      "url": "https://openapi-mcp.openapisearch.com/mcp"
    }
  }
}
```

## Tool Reference

### `searchAPIs`

Search for APIs relevant to a specific use case using semantic search. Returns matching APIs with descriptions and identifiers.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `query` | string | yes | What you want to do with an API (e.g. "send email notifications", "process payments") |
| `limit` | number | no | Max results to return (default: 5, max: 20) |

**Returns**: List of matching APIs with `apiId`, name, description, and relevance score.

### `getAPIOverview`

Get an overview of a specific API including its available endpoints and capabilities. Use after `searchAPIs` to explore a specific API.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `apiId` | string | yes | API identifier from `searchAPIs` results, or a URL to a raw OpenAPI file |

**Returns**: API summary with endpoint list, base URL, authentication info, and capability overview.

### `getOperationDetails`

Get detailed information about a specific API operation including parameters, request body schema, and response schema. Use after `getAPIOverview` to get specifics about an endpoint.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `apiId` | string | yes | API identifier |
| `operationId` | string | yes | Operation identifier from `getAPIOverview` results (e.g. `"POST /mail/send"`) |

**Returns**: Full operation details including path/query parameters, request body schema, response schemas, and authentication requirements.

## Usage Examples

### Discovering APIs for a Use Case

```text
# Find APIs for sending emails
searchAPIs(query: "send email notifications", limit: 5)

# Find APIs for payment processing
searchAPIs(query: "process credit card payments", limit: 5)

# Find APIs for weather data
searchAPIs(query: "get weather forecast by location", limit: 3)
```

### Exploring an API

```text
# Get overview of SendGrid API (apiId from searchAPIs results)
getAPIOverview(apiId: "sendgrid-v3")

# Get overview of Stripe API
getAPIOverview(apiId: "stripe.com")

# Get overview via raw OpenAPI URL
getAPIOverview(apiId: "https://petstore3.swagger.io/api/v3/openapi.json")
```

### Getting Operation Details

```text
# Get details for sending mail via SendGrid
getOperationDetails(apiId: "sendgrid-v3", operationId: "POST /mail/send")

# Get details for creating a Stripe payment intent
getOperationDetails(apiId: "stripe.com", operationId: "POST /v1/payment_intents")
```

### Full Discovery Workflow

```text
# 1. Search for relevant APIs
searchAPIs(query: "convert currency exchange rates")
# Returns: [{ apiId: "exchangerate-api", ... }, { apiId: "fixer.io", ... }]

# 2. Explore the best match
getAPIOverview(apiId: "exchangerate-api")
# Returns: endpoints list, base URL, auth info

# 3. Get details for the specific operation you need
getOperationDetails(apiId: "exchangerate-api", operationId: "GET /latest/{base}")
# Returns: parameters, response schema, example responses
```

## When to Use OpenAPI Search

**Use it when**:

- You need to find an API for a specific task and don't know which service to use
- You want to explore an API's endpoints before writing integration code
- You need request/response schemas for code generation
- You're comparing multiple APIs for the same use case

**Don't use it when**:

- You already know the exact API and have its documentation (use Context7 or direct docs)
- You need to test live API calls (this is read-only search over specs)
- You need internal/private API documentation (this indexes public OpenAPI specs)

## Agent Enablement

| Agent | Enabled | Rationale |
|-------|---------|-----------|
| `@openapi-search` | Yes | Dedicated subagent for API exploration |
| Build+ | No | Use `@openapi-search` subagent when needed |
| Research | No | Use `@openapi-search` subagent when needed |
| All others | No | Not relevant to domain tasks |

**Rationale**: OpenAPI exploration is a focused, on-demand task. Lazy-loading keeps
session startup fast and avoids unnecessary context overhead for sessions that don't
need API exploration.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENAPI_SEARCH_URL` | `https://search.apis.guru/v1` | Override the backend API URL |

## Verification

After configuring, test with:

```text
@openapi-search Use the openapi-search MCP to get an overview of the Stripe API.
```

Expected: A list of Stripe API endpoints with operation IDs and summaries.

## Troubleshooting

### MCP not responding

The server is a Cloudflare Worker — check connectivity:

```bash
curl -s https://openapi-mcp.openapisearch.com/mcp | head -5
```

### API identifier not found

Browse <https://openapisearch.com/search> to find the correct identifier.
You can also pass a direct URL to a raw OpenAPI file.

### Spec too large

Some very large APIs (e.g., AWS) may exceed the 250K character limit.
Try a more specific sub-spec URL if available.

## Updates

- **GitHub**: <https://github.com/janwilmake/openapi-mcp-server>
- **Directory**: <https://openapisearch.com>
- **Remote URL**: `https://openapi-mcp.openapisearch.com/mcp` (always latest)
