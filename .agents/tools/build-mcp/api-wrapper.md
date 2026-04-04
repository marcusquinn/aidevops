---
description: API wrapper pattern for REST API to MCP conversion
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# API Wrapper Pattern - REST API to MCP

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Template for wrapping any REST API as an MCP server
- **Stack**: TypeScript + Bun + ElysiaJS + elysia-mcp
- **Pattern**: One tool per API endpoint

**Steps**:

1. Identify API endpoints to expose
2. Create Zod schemas for inputs
3. Map HTTP methods to tools
4. Handle authentication via env vars
5. Return structured JSON responses

**Common patterns** (pagination, search, batch, file upload): `api-wrapper/patterns.md`

<!-- AI-CONTEXT-END -->

## Complete Template

```typescript
import { Elysia } from 'elysia';
import { mcp } from 'elysia-mcp';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';

const API_BASE = process.env.API_BASE_URL || 'https://api.example.com';
const API_KEY = process.env.API_KEY;

if (!API_KEY) {
  console.error('API_KEY environment variable is required');
  process.exit(1);
}

async function apiRequest(
  endpoint: string,
  method: 'GET' | 'POST' | 'PUT' | 'DELETE' = 'GET',
  body?: unknown
) {
  const response = await fetch(`${API_BASE}${endpoint}`, {
    method,
    headers: {
      'Authorization': `Bearer ${API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!response.ok) {
    const error = await response.text();
    throw new Error(`API Error ${response.status}: ${error}`);
  }
  return response.json();
}

// Shared error wrapper — use for every tool handler
function toolResult(data: unknown) {
  return { content: [{ type: 'text' as const, text: JSON.stringify(data, null, 2) }] };
}
function toolError(error: unknown) {
  return {
    content: [{ type: 'text' as const, text: JSON.stringify({ error: true, message: String(error) }) }],
    isError: true,
  };
}

const app = new Elysia()
  .use(
    mcp({
      serverInfo: { name: 'example-api-mcp', version: '1.0.0' },
      capabilities: { tools: {}, resources: {} },
      setupServer: async (server: McpServer) => {

        server.tool('list_items', {
          page: z.number().optional().default(1).describe('Page number'),
          limit: z.number().optional().default(20).describe('Items per page'),
          filter: z.string().optional().describe('Filter query'),
        }, async (args) => {
          try {
            const params = new URLSearchParams({
              page: String(args.page),
              limit: String(args.limit),
              ...(args.filter && { filter: args.filter }),
            });
            return toolResult(await apiRequest(`/items?${params}`));
          } catch (e) { return toolError(e); }
        });

        server.tool('get_item', {
          id: z.string().describe('Item ID'),
        }, async (args) => {
          try { return toolResult(await apiRequest(`/items/${args.id}`)); }
          catch (e) { return toolError(e); }
        });

        server.tool('create_item', {
          name: z.string().describe('Item name'),
          description: z.string().optional().describe('Item description'),
          tags: z.array(z.string()).optional().describe('Item tags'),
        }, async (args) => {
          try { return toolResult(await apiRequest('/items', 'POST', args)); }
          catch (e) { return toolError(e); }
        });

        server.tool('update_item', {
          id: z.string().describe('Item ID'),
          name: z.string().optional().describe('New name'),
          description: z.string().optional().describe('New description'),
          tags: z.array(z.string()).optional().describe('New tags'),
        }, async (args) => {
          try {
            const { id, ...updates } = args;
            return toolResult(await apiRequest(`/items/${id}`, 'PUT', updates));
          } catch (e) { return toolError(e); }
        });

        server.tool('delete_item', {
          id: z.string().describe('Item ID'),
          confirm: z.boolean().describe('Confirm deletion'),
        }, async (args) => {
          if (!args.confirm) return toolError('Deletion not confirmed');
          try {
            await apiRequest(`/items/${args.id}`, 'DELETE');
            return toolResult({ success: true, deleted: args.id });
          } catch (e) { return toolError(e); }
        });

        server.resource('API Documentation', 'resource://api-docs', async () => ({
          contents: [{
            uri: 'resource://api-docs',
            mimeType: 'text/markdown',
            text: `# Example API MCP\n\n## Tools\n- list_items, get_item, create_item, update_item, delete_item\n\n## Auth\nAPI key via \`API_KEY\` env var.\n`,
          }],
        }));
      },
    })
  )
  .listen(3000);

console.log('MCP Server running on http://localhost:3000/mcp');
```

## Stdio Version (for Claude Code / Claude)

```typescript
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';

const API_BASE = process.env.API_BASE_URL || 'https://api.example.com';
const API_KEY = process.env.API_KEY;

async function apiRequest(endpoint: string, method = 'GET', body?: unknown) {
  const response = await fetch(`${API_BASE}${endpoint}`, {
    method,
    headers: { 'Authorization': `Bearer ${API_KEY}`, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!response.ok) throw new Error(`API Error ${response.status}`);
  return response.json();
}

const server = new McpServer({ name: 'example-api-mcp', version: '1.0.0' });

server.tool('list_items', { limit: z.number().optional().default(20) }, async (args) => {
  const data = await apiRequest(`/items?limit=${args.limit}`);
  return { content: [{ type: 'text', text: JSON.stringify(data) }] };
});

// Add more tools...

const transport = new StdioServerTransport();
await server.connect(transport);
```

## OpenCode Configuration

```json
{
  "mcp": {
    "example-api": {
      "type": "local",
      "command": ["/bin/bash", "-c", "API_KEY=$EXAMPLE_API_KEY bun run /path/to/example-api-mcp/src/index.ts"],
      "enabled": true
    }
  }
}
```

## Testing

```bash
bun run src/index.ts

# MCP Inspector
npx @modelcontextprotocol/inspector
# Connect to http://localhost:3000/mcp

# Direct test
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'
```
