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

Best for local development and AI assistants that spawn the MCP server as a subprocess.

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

### Client Configuration

**OpenCode:**

```json
{ "mcp": { "my-mcp": { "type": "local", "command": ["bun", "run", "/path/to/my-mcp/src/index.ts"], "enabled": true } } }
```

**Claude Code:**

```bash
claude mcp add my-mcp bun run /path/to/my-mcp/src/index.ts
```

## Streamable HTTP Transport

Best for production deployments and web-accessible MCP servers.

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

`transport.sessionId` exposes the UUID for the current session.

**DNS rebinding protection** is auto-enabled when binding to `127.0.0.1`; disabled for `0.0.0.0`:

```typescript
import { createMcpExpressApp } from '@modelcontextprotocol/sdk/server/express.js';
const app = createMcpExpressApp({ host: '127.0.0.1' }); // protected
```

### With ElysiaJS (Recommended)

```typescript
import { Elysia } from 'elysia';
import { mcp } from 'elysia-mcp';
import { z } from 'zod';

const app = new Elysia()
  .use(mcp({
    serverInfo: { name: 'my-mcp', version: '1.0.0' },
    capabilities: { tools: {} },
    setupServer: async (server) => {
      server.tool(
        'hello',
        { name: z.string() },
        async (args) => ({ content: [{ type: 'text', text: `Hello, ${args.name}!` }] })
      );
    },
  }))
  .listen(3000);
```

## SSE Transport (Legacy)

For backwards compatibility with clients using protocol version 2024-11-05.

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

## Backwards Compatible Server

Support both Streamable HTTP and SSE on the same Express app:

```typescript
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { SSEServerTransport } from '@modelcontextprotocol/sdk/server/sse.js';
import express from 'express';
import { randomUUID } from 'crypto';

const server = new McpServer({ name: 'my-mcp', version: '1.0.0' });
const app = express();
app.use(express.json());
const sseTransports = new Map<string, SSEServerTransport>();

// Streamable HTTP (2025-03-26)
app.post('/mcp', async (req, res) => {
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: () => randomUUID() });
  res.on('close', () => transport.close());
  await server.connect(transport);
  await transport.handleRequest(req, res, req.body);
});

// SSE (2024-11-05 legacy)
app.get('/sse', (req, res) => {
  const transport = new SSEServerTransport('/messages', res);
  sseTransports.set(transport.sessionId, transport);
  res.on('close', () => { sseTransports.delete(transport.sessionId); transport.close(); });
  server.connect(transport);
});

app.post('/messages', (req, res) => {
  const transport = sseTransports.get(req.query.sessionId as string);
  transport ? transport.handlePostMessage(req, res, req.body) : res.status(404).json({ error: 'Session not found' });
});

app.listen(3000);
```

## Remote HTTP Configuration

**OpenCode:**

```json
{ "mcp": { "my-mcp": { "type": "remote", "url": "https://my-mcp.example.com/mcp", "enabled": true } } }
```

**Claude Desktop (via proxy):**

```json
{ "mcpServers": { "my-mcp": { "command": "npx", "args": ["-y", "mcp-remote-client", "https://my-mcp.example.com/mcp"] } } }
```

## Transport Selection

| Scenario | Transport |
|----------|-----------|
| Local dev / AI spawns process | stdio |
| Web deployment / multiple clients | StreamableHTTP |
| Legacy clients | SSE |
| New + old clients | Both (backwards compatible) |

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
