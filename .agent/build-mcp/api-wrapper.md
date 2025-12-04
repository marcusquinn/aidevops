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

<!-- AI-CONTEXT-END -->

## Complete Template

```typescript
import { Elysia } from 'elysia';
import { mcp } from 'elysia-mcp';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';

// Configuration
const API_BASE = process.env.API_BASE_URL || 'https://api.example.com';
const API_KEY = process.env.API_KEY;

if (!API_KEY) {
  console.error('API_KEY environment variable is required');
  process.exit(1);
}

// Helper for API requests
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

// MCP Server
const app = new Elysia()
  .use(
    mcp({
      serverInfo: {
        name: 'example-api-mcp',
        version: '1.0.0',
      },
      capabilities: {
        tools: {},
        resources: {},
      },
      setupServer: async (server: McpServer) => {
        // LIST endpoint
        server.tool(
          'list_items',
          {
            page: z.number().optional().default(1).describe('Page number'),
            limit: z.number().optional().default(20).describe('Items per page'),
            filter: z.string().optional().describe('Filter query'),
          },
          async (args) => {
            try {
              const params = new URLSearchParams({
                page: String(args.page),
                limit: String(args.limit),
                ...(args.filter && { filter: args.filter }),
              });
              const data = await apiRequest(`/items?${params}`);
              return {
                content: [{ type: 'text', text: JSON.stringify(data, null, 2) }],
              };
            } catch (error) {
              return {
                content: [{
                  type: 'text',
                  text: JSON.stringify({ error: true, message: String(error) }),
                }],
                isError: true,
              };
            }
          }
        );

        // GET endpoint
        server.tool(
          'get_item',
          {
            id: z.string().describe('Item ID'),
          },
          async (args) => {
            try {
              const data = await apiRequest(`/items/${args.id}`);
              return {
                content: [{ type: 'text', text: JSON.stringify(data, null, 2) }],
              };
            } catch (error) {
              return {
                content: [{
                  type: 'text',
                  text: JSON.stringify({ error: true, message: String(error) }),
                }],
                isError: true,
              };
            }
          }
        );

        // CREATE endpoint
        server.tool(
          'create_item',
          {
            name: z.string().describe('Item name'),
            description: z.string().optional().describe('Item description'),
            tags: z.array(z.string()).optional().describe('Item tags'),
          },
          async (args) => {
            try {
              const data = await apiRequest('/items', 'POST', args);
              return {
                content: [{ type: 'text', text: JSON.stringify(data, null, 2) }],
              };
            } catch (error) {
              return {
                content: [{
                  type: 'text',
                  text: JSON.stringify({ error: true, message: String(error) }),
                }],
                isError: true,
              };
            }
          }
        );

        // UPDATE endpoint
        server.tool(
          'update_item',
          {
            id: z.string().describe('Item ID'),
            name: z.string().optional().describe('New name'),
            description: z.string().optional().describe('New description'),
            tags: z.array(z.string()).optional().describe('New tags'),
          },
          async (args) => {
            try {
              const { id, ...updates } = args;
              const data = await apiRequest(`/items/${id}`, 'PUT', updates);
              return {
                content: [{ type: 'text', text: JSON.stringify(data, null, 2) }],
              };
            } catch (error) {
              return {
                content: [{
                  type: 'text',
                  text: JSON.stringify({ error: true, message: String(error) }),
                }],
                isError: true,
              };
            }
          }
        );

        // DELETE endpoint
        server.tool(
          'delete_item',
          {
            id: z.string().describe('Item ID'),
            confirm: z.boolean().describe('Confirm deletion'),
          },
          async (args) => {
            if (!args.confirm) {
              return {
                content: [{
                  type: 'text',
                  text: JSON.stringify({ error: true, message: 'Deletion not confirmed' }),
                }],
                isError: true,
              };
            }
            try {
              await apiRequest(`/items/${args.id}`, 'DELETE');
              return {
                content: [{
                  type: 'text',
                  text: JSON.stringify({ success: true, deleted: args.id }),
                }],
              };
            } catch (error) {
              return {
                content: [{
                  type: 'text',
                  text: JSON.stringify({ error: true, message: String(error) }),
                }],
                isError: true,
              };
            }
          }
        );

        // Expose API docs as resource
        server.resource('API Documentation', 'resource://api-docs', async () => ({
          contents: [{
            uri: 'resource://api-docs',
            mimeType: 'text/markdown',
            text: `# Example API MCP

## Available Tools

- \`list_items\` - List all items with pagination
- \`get_item\` - Get a single item by ID
- \`create_item\` - Create a new item
- \`update_item\` - Update an existing item
- \`delete_item\` - Delete an item (requires confirmation)

## Authentication

API key is configured via \`API_KEY\` environment variable.
`,
          }],
        }));
      },
    })
  )
  .listen(3000);

console.log('MCP Server running on http://localhost:3000/mcp');
```

## Stdio Version (for OpenCode/Claude)

```typescript
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';

const API_BASE = process.env.API_BASE_URL || 'https://api.example.com';
const API_KEY = process.env.API_KEY;

async function apiRequest(endpoint: string, method = 'GET', body?: unknown) {
  const response = await fetch(`${API_BASE}${endpoint}`, {
    method,
    headers: {
      'Authorization': `Bearer ${API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!response.ok) throw new Error(`API Error ${response.status}`);
  return response.json();
}

const server = new McpServer({
  name: 'example-api-mcp',
  version: '1.0.0',
});

server.tool(
  'list_items',
  { limit: z.number().optional().default(20) },
  async (args) => {
    const data = await apiRequest(`/items?limit=${args.limit}`);
    return { content: [{ type: 'text', text: JSON.stringify(data) }] };
  }
);

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
      "command": [
        "/bin/bash",
        "-c",
        "API_KEY=$EXAMPLE_API_KEY bun run /path/to/example-api-mcp/src/index.ts"
      ],
      "enabled": true
    }
  }
}
```

## Common API Patterns

### Pagination

```typescript
server.tool(
  'list_paginated',
  {
    cursor: z.string().optional().describe('Pagination cursor'),
    limit: z.number().optional().default(50).describe('Items per page'),
  },
  async (args) => {
    const params = new URLSearchParams({ limit: String(args.limit) });
    if (args.cursor) params.set('cursor', args.cursor);
    
    const data = await apiRequest(`/items?${params}`);
    return {
      content: [{
        type: 'text',
        text: JSON.stringify({
          items: data.items,
          nextCursor: data.next_cursor,
          hasMore: !!data.next_cursor,
        }, null, 2),
      }],
    };
  }
);
```

### Search

```typescript
server.tool(
  'search',
  {
    query: z.string().describe('Search query'),
    fields: z.array(z.string()).optional().describe('Fields to search'),
    sort: z.enum(['relevance', 'date', 'name']).optional().default('relevance'),
  },
  async (args) => {
    const data = await apiRequest('/search', 'POST', {
      q: args.query,
      fields: args.fields,
      sort: args.sort,
    });
    return {
      content: [{ type: 'text', text: JSON.stringify(data, null, 2) }],
    };
  }
);
```

### Batch Operations

```typescript
server.tool(
  'batch_update',
  {
    ids: z.array(z.string()).describe('Item IDs to update'),
    updates: z.object({
      status: z.string().optional(),
      tags: z.array(z.string()).optional(),
    }).describe('Updates to apply'),
  },
  async (args) => {
    const results = await Promise.all(
      args.ids.map(id => 
        apiRequest(`/items/${id}`, 'PUT', args.updates)
          .then(data => ({ id, success: true, data }))
          .catch(error => ({ id, success: false, error: String(error) }))
      )
    );
    return {
      content: [{ type: 'text', text: JSON.stringify(results, null, 2) }],
    };
  }
);
```

### File Upload

```typescript
server.tool(
  'upload_file',
  {
    filename: z.string().describe('File name'),
    content: z.string().describe('Base64 encoded file content'),
    mimeType: z.string().optional().default('application/octet-stream'),
  },
  async (args) => {
    const response = await fetch(`${API_BASE}/upload`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${API_KEY}`,
        'Content-Type': args.mimeType,
        'X-Filename': args.filename,
      },
      body: Buffer.from(args.content, 'base64'),
    });
    const data = await response.json();
    return {
      content: [{ type: 'text', text: JSON.stringify(data, null, 2) }],
    };
  }
);
```

## Testing

```bash
# Start server
bun run src/index.ts

# Test with MCP Inspector
npx @modelcontextprotocol/inspector
# Connect to http://localhost:3000/mcp

# Or test directly
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'
```
