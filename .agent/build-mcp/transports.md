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
  list: true
  webfetch: true
---

# MCP Transports - stdio, HTTP, SSE

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Configure MCP server transports for different deployment scenarios
- **Recommended**: stdio for local, StreamableHTTP for production

| Transport | Protocol | Use Case |
|-----------|----------|----------|
| `StdioServerTransport` | stdio | Local dev, spawned by AI assistants |
| `StreamableHTTPServerTransport` | 2025-03-26 | Production HTTP servers |
| `SSEServerTransport` | 2024-11-05 | Legacy compatibility |

<!-- AI-CONTEXT-END -->

## Stdio Transport

Best for local development and when AI assistants spawn the MCP server as a subprocess.

### Basic Setup

```typescript
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';

const server = new McpServer({
  name: 'my-mcp',
  version: '1.0.0',
});

// Register tools
server.tool(
  'hello',
  { name: z.string() },
  async (args) => ({
    content: [{ type: 'text', text: `Hello, ${args.name}!` }],
  })
);

// Connect via stdio
const transport = new StdioServerTransport();
await server.connect(transport);
```

### OpenCode Configuration

```json
{
  "mcp": {
    "my-mcp": {
      "type": "local",
      "command": ["bun", "run", "/path/to/my-mcp/src/index.ts"],
      "enabled": true
    }
  }
}
```

### Claude Code Configuration

```bash
claude mcp add my-mcp bun run /path/to/my-mcp/src/index.ts
```

### Logging with Stdio

Since stdout is used for MCP communication, use stderr for logging:

```typescript
// Good - logs to stderr
console.error('[DEBUG] Processing request');

// Bad - interferes with MCP protocol
console.log('[DEBUG] Processing request');
```

## Streamable HTTP Transport

Best for production deployments and web-accessible MCP servers.

### With Express

```typescript
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import express from 'express';
import { randomUUID } from 'crypto';

const server = new McpServer({
  name: 'my-mcp',
  version: '1.0.0',
});

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

app.listen(3000, () => {
  console.log('MCP Server running on http://localhost:3000/mcp');
});
```

### With ElysiaJS (Recommended)

```typescript
import { Elysia } from 'elysia';
import { mcp } from 'elysia-mcp';
import { z } from 'zod';

const app = new Elysia()
  .use(
    mcp({
      serverInfo: { name: 'my-mcp', version: '1.0.0' },
      capabilities: { tools: {} },
      setupServer: async (server) => {
        server.tool(
          'hello',
          { name: z.string() },
          async (args) => ({
            content: [{ type: 'text', text: `Hello, ${args.name}!` }],
          })
        );
      },
    })
  )
  .listen(3000);
```

### DNS Rebinding Protection

For localhost servers, enable DNS rebinding protection:

```typescript
import { createMcpExpressApp } from '@modelcontextprotocol/sdk/server/express.js';

// Protection auto-enabled for localhost
const app = createMcpExpressApp({ host: '127.0.0.1' });

// No protection when binding to all interfaces
const app = createMcpExpressApp({ host: '0.0.0.0' });
```

### Session Management

```typescript
const transport = new StreamableHTTPServerTransport({
  sessionIdGenerator: () => randomUUID(),
  enableJsonResponse: true,
});

// Access session ID
transport.sessionId; // UUID string
```

## SSE Transport (Legacy)

For backwards compatibility with older clients using protocol version 2024-11-05.

### Basic SSE Server

```typescript
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { SSEServerTransport } from '@modelcontextprotocol/sdk/server/sse.js';
import express from 'express';

const server = new McpServer({
  name: 'my-mcp',
  version: '1.0.0',
});

const app = express();
const transports = new Map<string, SSEServerTransport>();

// SSE endpoint for streaming
app.get('/sse', (req, res) => {
  const transport = new SSEServerTransport('/messages', res);
  const sessionId = transport.sessionId;
  transports.set(sessionId, transport);
  
  res.on('close', () => {
    transports.delete(sessionId);
    transport.close();
  });
  
  server.connect(transport);
});

// Message endpoint
app.post('/messages', express.json(), (req, res) => {
  const sessionId = req.query.sessionId as string;
  const transport = transports.get(sessionId);
  
  if (!transport) {
    res.status(404).json({ error: 'Session not found' });
    return;
  }
  
  transport.handlePostMessage(req, res, req.body);
});

app.listen(3000);
```

## Backwards Compatible Server

Support both Streamable HTTP and SSE transports:

```typescript
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { SSEServerTransport } from '@modelcontextprotocol/sdk/server/sse.js';
import express from 'express';
import { randomUUID } from 'crypto';

const server = new McpServer({
  name: 'my-mcp',
  version: '1.0.0',
});

const app = express();
app.use(express.json());

const sseTransports = new Map<string, SSEServerTransport>();

// Streamable HTTP (new protocol)
app.post('/mcp', async (req, res) => {
  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: () => randomUUID(),
  });
  res.on('close', () => transport.close());
  await server.connect(transport);
  await transport.handleRequest(req, res, req.body);
});

// SSE (legacy protocol)
app.get('/sse', (req, res) => {
  const transport = new SSEServerTransport('/messages', res);
  sseTransports.set(transport.sessionId, transport);
  res.on('close', () => {
    sseTransports.delete(transport.sessionId);
    transport.close();
  });
  server.connect(transport);
});

app.post('/messages', (req, res) => {
  const sessionId = req.query.sessionId as string;
  const transport = sseTransports.get(sessionId);
  if (transport) {
    transport.handlePostMessage(req, res, req.body);
  } else {
    res.status(404).json({ error: 'Session not found' });
  }
});

app.listen(3000, () => {
  console.log('MCP Server running:');
  console.log('  Streamable HTTP: http://localhost:3000/mcp');
  console.log('  SSE (legacy): http://localhost:3000/sse');
});
```

## Remote HTTP Configuration

For AI assistants connecting to remote MCP servers:

### OpenCode

```json
{
  "mcp": {
    "my-mcp": {
      "type": "remote",
      "url": "https://my-mcp.example.com/mcp",
      "enabled": true
    }
  }
}
```

### Claude Desktop (via proxy)

```json
{
  "mcpServers": {
    "my-mcp": {
      "command": "npx",
      "args": ["-y", "mcp-remote-client", "https://my-mcp.example.com/mcp"]
    }
  }
}
```

## Transport Selection Guide

| Scenario | Transport | Why |
|----------|-----------|-----|
| Local development | stdio | Simple, no server needed |
| AI assistant spawns process | stdio | Direct communication |
| Web deployment | StreamableHTTP | Standard HTTP, scalable |
| Multiple clients | StreamableHTTP | Session management |
| Legacy clients | SSE | Backwards compatibility |
| Both new and old clients | Both | Maximum compatibility |

## Testing Transports

### Test stdio

```bash
# Run server
bun run src/index.ts

# Server reads from stdin, writes to stdout
echo '{"jsonrpc":"2.0","method":"tools/list","id":1}' | bun run src/index.ts
```

### Test HTTP

```bash
# Start server
bun run src/index.ts

# Test with curl
curl -X POST http://localhost:3000/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'
```

### Test with MCP Inspector

```bash
npx @modelcontextprotocol/inspector

# Connect to:
# - stdio: Run command directly
# - HTTP: http://localhost:3000/mcp
# - SSE: http://localhost:3000/sse
```
