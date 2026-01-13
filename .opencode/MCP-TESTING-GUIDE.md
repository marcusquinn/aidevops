# MCP Testing Guide with Inspector

This guide covers testing MCP servers and the Elysia API Gateway using the MCP Inspector.

## Quick Start

### 1. Start Local Servers

```bash
# Terminal 1: Start API Gateway (port 3100)
bun run dev

# Terminal 2: Start MCP Dashboard (port 3101)  
bun run dashboard
```

### 2. Run Health Check

```bash
./.agent/scripts/mcp-inspector-helper.sh health
```

### 3. Test API Gateway

```bash
./.agent/scripts/mcp-inspector-helper.sh test-gateway
```

## MCP Inspector Commands

### Launch Web UI

The web UI provides interactive testing at `http://localhost:6274`:

```bash
# Launch with all configured servers
./.agent/scripts/mcp-inspector-helper.sh ui

# Launch for specific server
./.agent/scripts/mcp-inspector-helper.sh ui context7
```

### List Tools

```bash
# List tools from all servers
./.agent/scripts/mcp-inspector-helper.sh list-tools

# List tools from specific server
./.agent/scripts/mcp-inspector-helper.sh list-tools context7
./.agent/scripts/mcp-inspector-helper.sh list-tools repomix
```

### Call Tools

```bash
# Call Context7 resolve-library-id
./.agent/scripts/mcp-inspector-helper.sh call-tool context7 resolve-library-id libraryName=bun

# Call Repomix pack_codebase
./.agent/scripts/mcp-inspector-helper.sh call-tool repomix pack_codebase directory=/path/to/repo
```

### List Resources

```bash
./.agent/scripts/mcp-inspector-helper.sh list-resources
./.agent/scripts/mcp-inspector-helper.sh list-resources filesystem
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

```bash
# Connect to HTTP server
npx @modelcontextprotocol/inspector --cli http://localhost:3100 --transport http --method tools/list

# With custom headers
npx @modelcontextprotocol/inspector --cli http://localhost:3100 \
  --transport http \
  --method tools/list \
  --header "Authorization: Bearer token"
```

## API Gateway Endpoints

### Health & Status

```bash
# Health check
curl http://localhost:3100/health

# Cache statistics
curl http://localhost:3100/api/cache/stats

# Clear cache
curl -X DELETE http://localhost:3100/api/cache
```

### SonarCloud Integration

```bash
# Get issues
curl http://localhost:3100/api/sonarcloud/issues

# Get quality gate status
curl http://localhost:3100/api/sonarcloud/status

# Get metrics
curl http://localhost:3100/api/sonarcloud/metrics
```

### Quality Summary

```bash
# Unified quality summary (cached)
curl http://localhost:3100/api/quality/summary
```

### Crawl4AI Proxy

```bash
# Check Crawl4AI health
curl http://localhost:3100/api/crawl4ai/health

# Crawl a URL (requires Crawl4AI running)
curl -X POST http://localhost:3100/api/crawl4ai/crawl \
  -H "Content-Type: application/json" \
  -d '{"urls": ["https://example.com"]}'
```

## MCP Dashboard

Access at `http://localhost:3101` for:

- Real-time server status monitoring
- Start/stop MCP servers
- WebSocket-based live updates
- Server health checks

### WebSocket Connection

```javascript
const ws = new WebSocket('ws://localhost:3101/ws')
ws.onmessage = (e) => console.log(JSON.parse(e.data))
```

## Configuration

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
   ./.agent/scripts/mcp-inspector-helper.sh health
   ```

2. Check server logs:

   ```bash
   bun run dev 2>&1 | tee server.log
   ```

3. Test direct connection:

   ```bash
   curl -v http://localhost:3100/health
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

```bash
# Install hey (HTTP load generator)
brew install hey

# Benchmark health endpoint
hey -n 1000 -c 10 http://localhost:3100/health

# Benchmark quality summary (with caching)
hey -n 100 -c 5 http://localhost:3100/api/quality/summary
```

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
const response = await fetch('http://localhost:3100/api/quality/summary')
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

.agent/scripts/
└── mcp-inspector-helper.sh     # Inspector helper script
```
