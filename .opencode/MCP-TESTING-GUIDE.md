<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# MCP Testing Guide with Inspector

This guide covers testing MCP servers and the Elysia API Gateway using the MCP Inspector.

## Quick Start

### 1. Start Local Servers

Generate local bearer tokens in trusted shells. Do not commit the values:

```bash
# Terminal 1: Start API Gateway (port 3100)
export API_GATEWAY_TOKEN="$(openssl rand -hex 32)"
bun run dev

# Terminal 2: Start MCP Dashboard (port 3101)
export DASHBOARD_TOKEN="$(openssl rand -hex 32)"
bun run dashboard
```

Both servers bind to `127.0.0.1` by default and refuse to start without their token.
Keep `API_GATEWAY_TOKEN` available in shells that run gateway checks. Enter
`DASHBOARD_TOKEN` in the dashboard when prompted; it is retained only in session storage.

For direct gateway requests, define this Bash helper so the token is passed through an
anonymous configuration stream instead of appearing in process arguments:

```bash
gateway_curl() {
  local url="$1"
  shift
  curl --fail --silent --show-error \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$API_GATEWAY_TOKEN") \
    "$@" "$url"
}
```

### 2. Run Health Check

```bash
./.agents/scripts/mcp-inspector-helper.sh health
```

### 3. Test API Gateway

```bash
./.agents/scripts/mcp-inspector-helper.sh test-gateway
```

## MCP Inspector Commands

### Launch Web UI

The web UI provides interactive testing at `http://localhost:6274`:

```bash
# Launch with all configured servers
./.agents/scripts/mcp-inspector-helper.sh ui

# Launch for specific server
./.agents/scripts/mcp-inspector-helper.sh ui context7
```

### List Tools

```bash
# List tools from all servers
./.agents/scripts/mcp-inspector-helper.sh list-tools

# List tools from specific server
./.agents/scripts/mcp-inspector-helper.sh list-tools context7
./.agents/scripts/mcp-inspector-helper.sh list-tools repomix
```

### Call Tools

```bash
# Call Context7 resolve-library-id
./.agents/scripts/mcp-inspector-helper.sh call-tool context7 resolve-library-id libraryName=bun

# Call Repomix pack_codebase
./.agents/scripts/mcp-inspector-helper.sh call-tool repomix pack_codebase directory=/path/to/repo
```

### List Resources

```bash
./.agents/scripts/mcp-inspector-helper.sh list-resources
./.agents/scripts/mcp-inspector-helper.sh list-resources filesystem
```

## Direct npx Commands

### Basic Usage

```bash
# Launch web UI for a stdio server
npx @modelcontextprotocol/inspector npx -y @context7/mcp-server@latest

# Launch web UI for Repomix
npx @modelcontextprotocol/inspector npx -y repomix@latest --mcp

# CLI mode - list tools
npx @modelcontextprotocol/inspector --cli npx -y @context7/mcp-server@latest --method tools/list
```

### With Config File

```bash
# Use config file
npx @modelcontextprotocol/inspector --config .opencode/server/mcp-test-config.json

# Specific server from config
npx @modelcontextprotocol/inspector --config .opencode/server/mcp-test-config.json --server context7
```

### HTTP/SSE Servers

Do not pass bearer tokens through the Inspector's `--header` option: command-line
arguments can be visible to other local processes. Use a protected Inspector
configuration mechanism or the `gateway_curl` helper for gateway HTTP endpoints.

## API Gateway Endpoints

### Health & Status

```bash
# Health check
gateway_curl http://localhost:3100/health

# Cache statistics
gateway_curl http://localhost:3100/api/cache/stats

# Clear cache
gateway_curl http://localhost:3100/api/cache -X DELETE
```

### SonarCloud Integration

```bash
# Get issues
gateway_curl http://localhost:3100/api/sonarcloud/issues

# Get quality gate status
gateway_curl http://localhost:3100/api/sonarcloud/status

# Get metrics
gateway_curl http://localhost:3100/api/sonarcloud/metrics
```

### Quality Summary

```bash
# Unified quality summary (cached)
gateway_curl http://localhost:3100/api/quality/summary
```

### Crawl4AI Proxy

```bash
# Check Crawl4AI health
gateway_curl http://localhost:3100/api/crawl4ai/health

# Crawl a URL (requires Crawl4AI running)
gateway_curl http://localhost:3100/api/crawl4ai/crawl \
  -X POST -H "Content-Type: application/json" -d '{"urls": ["https://example.com"]}'
```

## MCP Dashboard

Access at `http://localhost:3101` for:

- Real-time server status monitoring
- Authenticated status and start/stop controls
- WebSocket-based live updates
- Server health checks

### WebSocket Connection

```javascript
const ws = new WebSocket('ws://localhost:3101/ws')
ws.onmessage = (e) => console.log(JSON.parse(e.data))
```

## Configuration

### Local Server Security

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `API_GATEWAY_TOKEN` | Yes | None | Bearer token required by every gateway endpoint |
| `DASHBOARD_TOKEN` | Yes | None | Bearer token required by dashboard status and control endpoints |
| `API_GATEWAY_HOST` | No | `127.0.0.1` | Gateway listen host |
| `MCP_DASHBOARD_HOST` | No | `127.0.0.1` | Dashboard listen host |
| `CORS_ORIGINS` | No | None | Comma-separated explicit HTTP(S) origins; wildcard values are rejected |

Setting either host to `0.0.0.0` is an explicit network-exposure opt-in. Authentication
remains mandatory; use TLS plus additional firewall and network controls.

### Config File Location

```text
.opencode/server/mcp-test-config.json
```

### Adding New Servers

```json
{
  "mcpServers": {
    "my-server": {
      "type": "stdio",
      "command": "node",
      "args": ["path/to/server.js"],
      "env": {
        "API_KEY": "secret"
      },
      "description": "My custom MCP server"
    }
  }
}
```

### Server Types

| Type | Description | Example |
|------|-------------|---------|
| `stdio` | Local process via stdin/stdout | Most MCP servers |
| `sse` | Server-Sent Events (deprecated) | Legacy servers |
| `streamable-http` | HTTP with streaming | Elysia servers |

## Troubleshooting

### Server Not Responding

1. Check if server is running:

   ```bash
   ./.agents/scripts/mcp-inspector-helper.sh health
   ```

2. Check server logs:

   ```bash
   bun run dev 2>&1 | tee server.log
   ```

3. Test direct connection:

   ```bash
   gateway_curl http://localhost:3100/health --verbose
   ```

### Inspector Connection Failed

1. Ensure server is started first
2. Check port availability:

   ```bash
   lsof -i :3100
   lsof -i :3101
   ```

3. Try with verbose output:

   ```bash
   DEBUG=* npx @modelcontextprotocol/inspector --cli ...
   ```

### Stdio Server Issues

1. Test command directly:

   ```bash
   npx -y @context7/mcp-server@latest
   ```

2. Check for missing dependencies
3. Verify environment variables are set

## Performance Testing

### Benchmark API Gateway

Avoid benchmark clients that accept authorization headers only through command-line
arguments, because they expose the token through process inspection. Use an isolated,
disposable gateway token and a client that accepts headers through protected standard input.

### Expected Performance

| Endpoint | Cached | Uncached |
|----------|--------|----------|
| `/health` | ~1ms | ~1ms |
| `/api/quality/summary` | ~2ms | ~500ms |
| `/api/sonarcloud/issues` | ~2ms | ~300ms |

## Integration with OpenCode

The API Gateway integrates with OpenCode tools:

```typescript
// In .opencode/tool/quality-check.ts
const response = await fetch('http://localhost:3100/api/quality/summary', {
  headers: { Authorization: `Bearer ${process.env.API_GATEWAY_TOKEN}` },
})
const data = await response.json()
```

## Files Reference

```text
.opencode/
├── server/
│   ├── api-gateway.ts          # Main API gateway
│   ├── mcp-dashboard.ts        # Dashboard with WebSocket
│   ├── index.ts                # Entry point
│   └── mcp-test-config.json    # MCP server config
├── lib/
│   ├── config-cache.ts         # SQLite caching
│   └── toon.ts                 # TOON format processing
└── tool/
    ├── parallel-quality.ts     # Parallel quality checks
    └── toon.ts                 # TOON OpenCode tool

.agents/scripts/
└── mcp-inspector-helper.sh     # Inspector helper script
```
