---
description: Cloudflare Code Mode MCP — Workers, D1, KV, R2, Pages, AI Gateway
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  cloudflare-api_*: true
---

# Cloudflare Code Mode MCP

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Server**: `https://mcp.cloudflare.com/mcp` (remote)
- **Auth**: OAuth 2.0 browser flow on first use
- **Config key**: `cloudflare-api` in `configs/mcp-servers-config.json.txt`
- **Setup**: `aidevops/mcp-integrations.md` → Cloudflare Code Mode MCP
- **Platform reference**: `services/hosting/cloudflare-platform-skill.md`
- **Capabilities**: Workers, D1, KV, R2, Pages, AI Gateway, DNS, Analytics
- **Per-agent**: Set `cloudflare-api_*: true` in subagent frontmatter (disabled globally, enabled per agent)

<!-- AI-CONTEXT-END -->

## Security

- **Scopes**: Access matches Cloudflare dashboard permissions
- **Secrets**: No tokens in config; MCP client stores OAuth token
- **Revocation**: `dash.cloudflare.com` → My Profile → API Tokens → OAuth Apps
- **Least privilege**: Use a sub-account or scoped API token for tighter scope; see `services/hosting/cloudflare.md`
- **Audit trail**: Actions appear in the Cloudflare audit log

## Auth Setup

First tool call opens `dash.cloudflare.com` for OAuth 2.0 authorization.

**Claude Desktop** (`~/Library/Application Support/Claude/claude_desktop_config.json`)
```json
{ "mcpServers": { "cloudflare-api": { "url": "https://mcp.cloudflare.com/mcp" } } }
```

**OpenCode** (`~/.config/opencode/config.json`)
```json
{ "mcp": { "cloudflare-api": { "type": "remote", "url": "https://mcp.cloudflare.com/mcp" } } }
```

**Claude Code CLI** (`--transport http` required even with HTTPS endpoint)
```bash
claude mcp add cloudflare-api --transport http https://mcp.cloudflare.com/mcp
```

## Usage Patterns

| Service | Typical prompts |
|---------|-----------------|
| **Workers** | `List all Workers` · `Show code for Worker "api-gateway"` · `Deploy ./src/worker.ts as "my-worker"` · `Tail logs for "my-worker"` |
| **D1** | `List D1 databases` · `Run SQL: SELECT * FROM users LIMIT 10 on "prod-db"` · `Show schema for "prod-db"` |
| **KV** | `List KV namespaces` · `Get key "config:feature-flags" from "APP_CONFIG"` · `List keys with prefix "user:" in "APP_DATA"` |
| **R2** | `List R2 buckets` · `List objects in "assets" with prefix "images/"` · `Upload ./dist/app.js to "releases" as "v1.2.3/app.js"` |
| **Pages** | `List Pages projects` · `Show deployments for "my-site"` · `Trigger deployment for "my-site"` |
| **AI Gateway** | `List AI Gateways` · `Show logs for "production"` · `Get analytics for last 24h` |
| **DNS** | `List DNS records for "example.com"` · `Add A record: api.example.com → 1.2.3.4 TTL 300` |

### Multi-Step Examples

```text
# Deploy Worker with bindings
Read ./src/worker.ts and deploy as "my-api". Bind to KV namespace "APP_DATA" and D1 "prod-db".

# Query D1
On "analytics" D1: SELECT date, count(*) as visits FROM page_views
WHERE date >= date('now', '-7 days') GROUP BY date ORDER BY date DESC

# Sync to R2
Upload all files in ./dist/ to R2 "static-assets" under prefix "v2.1.0/". List to confirm.
```

## Related Docs

- `services/hosting/cloudflare.md` — DNS/CDN API setup, token scoping, security
- `services/hosting/cloudflare-platform-skill.md` — Full platform reference (Workers, D1, R2, KV, Pages, AI, 60 products)
- `aidevops/mcp-integrations.md` — All MCP integrations overview and setup
- `configs/mcp-servers-config.json.txt` — Master MCP server config template
