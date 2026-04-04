---
description: MCP transport protocols - stdio, HTTP, SSE
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

# MCP Transports - stdio, HTTP, SSE

<!-- AI-CONTEXT-START -->

## Quick Reference

| Transport | Protocol | Use Case |
|-----------|----------|----------|
| `StdioServerTransport` | stdio | Local dev, spawned by AI assistants |
| `StreamableHTTPServerTransport` | 2025-03-26 | Production HTTP servers |
| `SSEServerTransport` | 2024-11-05 | Legacy compatibility |

<!-- AI-CONTEXT-END -->

## Stdio Transport

```typescript
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';

const server = new McpServer({ name: 'my-mcp', version: '1.0.0' });
server.tool(
  'hello',
  { name: z.string() },
  async (args) => ({ content: [{ type: 'text', text: `Hello, ${args.name}!` }] })
);

const transport = new StdioServerTransport();
await server.connect(transport);
```

**Logging:** stdout is reserved for MCP protocol — use `console.error(...)` for debug output.

### Client Config

- **Claude Code:** `claude mcp add my-mcp bun run /path/to/my-mcp/src/index.ts`
- **OpenCode:** `{ "mcp": { "my-mcp": { "type": "local", "command": ["bun", "run", "/path/to/my-mcp/src/index.ts"], "enabled": true } } }`

## Streamable HTTP Transport

### With Express

```typescript
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import express from 'express';
import { randomUUID } from 'crypto';

const server = new McpServer({ name: 'my-mcp', version: '1.0.0' });
// Register tools...
const app = express();
app.use(express.json());

app.post('/mcp', async (req, res) => {
  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: () => randomUUID(),
    enableJsonResponse: true,
  });
  res.on('close', () => transport.close());
  await server.connect(transport);
  await transport.handleRequest(req, res, req.body);
});

app.listen(3000);
```

`transport.sessionId` exposes the UUID for the current session. DNS rebinding protection is auto-enabled on `127.0.0.1` (via `createMcpExpressApp`), disabled for `0.0.0.0`.

### With ElysiaJS (Recommended)

```typescript
import { Elysia } from 'elysia';
import { mcp } from 'elysia-mcp';

const app = new Elysia()
  .use(mcp({
    serverInfo: { name: 'my-mcp', version: '1.0.0' },
    capabilities: { tools: {} },
    setupServer: async (server) => {
      server.tool('hello', { name: z.string() }, async (args) =>
        ({ content: [{ type: 'text', text: `Hello, ${args.name}!` }] }));
    },
  }))
  .listen(3000);
```

### Client Config

- **OpenCode:** `{ "mcp": { "my-mcp": { "type": "remote", "url": "https://my-mcp.example.com/mcp", "enabled": true } } }`
- **Claude Desktop (via proxy):** `{ "mcpServers": { "my-mcp": { "command": "npx", "args": ["-y", "mcp-remote-client", "https://my-mcp.example.com/mcp"] } } }`

## SSE Transport (Legacy — protocol 2024-11-05)

```typescript
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { SSEServerTransport } from '@modelcontextprotocol/sdk/server/sse.js';
import express from 'express';

const server = new McpServer({ name: 'my-mcp', version: '1.0.0' });
const app = express();
const transports = new Map<string, SSEServerTransport>();
app.get('/sse', (req, res) => {
  const transport = new SSEServerTransport('/messages', res);
  transports.set(transport.sessionId, transport);
  res.on('close', () => { transports.delete(transport.sessionId); transport.close(); });
  server.connect(transport);
});
app.post('/messages', express.json(), (req, res) => {
  const transport = transports.get(req.query.sessionId as string);
  if (!transport) { res.status(404).json({ error: 'Session not found' }); return; }
  transport.handlePostMessage(req, res, req.body);
});

app.listen(3000);
```

**Backwards compatible server:** To support both Streamable HTTP and SSE on the same Express app, combine the `/mcp` POST handler from the Express example above with the `/sse` GET and `/messages` POST handlers from this section.

## Testing

```bash
# stdio
echo '{"jsonrpc":"2.0","method":"tools/list","id":1}' | bun run src/index.ts

# HTTP
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'

# MCP Inspector
npx @modelcontextprotocol/inspector
# Connect: stdio (run command), HTTP (localhost:3000/mcp), SSE (localhost:3000/sse)
```
