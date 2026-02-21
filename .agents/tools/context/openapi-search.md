---
description: OpenAPI Search MCP — search and explore any OpenAPI spec via 3-step process
mode: subagent
tools:
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
- **MCP Tools**:
  - `getApiOverview` — Get a summary of any API's endpoints (step 1)
  - `getApiOperation` — Get details about a specific endpoint (step 2)
- **Docs**: <https://github.com/janwilmake/openapi-mcp-server>
- **Directory**: <https://openapisearch.com/search>
- **Stars**: 875 (MIT license)

**3-Step Process**:

1. Find the API identifier from <https://openapisearch.com/search> or use a raw OpenAPI URL
2. Call `getApiOverview(id)` to get a summary of all endpoints
3. Call `getApiOperation(id, operationIdOrRoute)` to drill into a specific endpoint

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
The 3-step process (find → overview → endpoint detail) keeps context usage minimal.

<!-- AI-CONTEXT-END -->

## What It Does

OpenAPI Search MCP lets LLMs navigate complex API specifications without loading entire
OpenAPI documents into context. It uses a 3-step process:

| Step | Tool | Purpose |
|------|------|---------|
| 1 | Browse <https://openapisearch.com/search> | Find the API identifier |
| 2 | `getApiOverview(id)` | Get a plain-language summary of all endpoints |
| 3 | `getApiOperation(id, operationId)` | Get full details for a specific endpoint |

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

## MCP Tools Reference

### `getApiOverview`

Get a plain-language overview of all endpoints in an API.

**Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | API identifier from openapisearch.com, or a URL to a raw OpenAPI file |

**Example**:

```text
getApiOverview({ id: "stripe" })
getApiOverview({ id: "https://raw.githubusercontent.com/example/api/main/openapi.yaml" })
```

**Returns**: Plain-language list of all endpoints with operation IDs, HTTP methods, paths, and summaries.

### `getApiOperation`

Get detailed information about a specific API endpoint.

**Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `id` | string | Yes | Same API identifier as used in `getApiOverview` |
| `operationIdOrRoute` | string | Yes | Operation ID (e.g., `createPaymentIntent`) or route path (e.g., `/v1/payment_intents`) |

**Example**:

```text
getApiOperation({ id: "stripe", operationIdOrRoute: "createPaymentIntent" })
getApiOperation({ id: "github", operationIdOrRoute: "/repos/{owner}/{repo}/issues" })
```

**Returns**: Full YAML spec for the endpoint including parameters, request body schema, and response schemas.

## Usage Examples

### Explore a Known API

```text
1. getApiOverview({ id: "stripe" })
   → Lists all Stripe endpoints with operation IDs

2. getApiOperation({ id: "stripe", operationIdOrRoute: "createPaymentIntent" })
   → Full spec for POST /v1/payment_intents
```

### Explore an API by URL

```text
1. getApiOverview({ id: "https://petstore3.swagger.io/api/v3/openapi.json" })
   → Lists all Petstore endpoints

2. getApiOperation({ id: "https://petstore3.swagger.io/api/v3/openapi.json", operationIdOrRoute: "addPet" })
   → Full spec for POST /pet
```

### Find Available APIs

Browse the directory at <https://openapisearch.com/search> to find API identifiers.
Common identifiers include: `stripe`, `github`, `openai`, `twilio`, `sendgrid`, `shopify`.

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
