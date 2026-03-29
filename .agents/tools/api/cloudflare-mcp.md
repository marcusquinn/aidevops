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

- **Server**: `https://mcp.cloudflare.com/mcp` (remote, no install)
- **Auth**: OAuth 2.0 via Cloudflare dashboard (browser flow on first connect)
- **Config key**: `cloudflare-api` in `configs/mcp-servers-config.json.txt`
- **Setup guide**: `aidevops/mcp-integrations.md` → Cloudflare Code Mode MCP section
- **Platform docs**: `services/hosting/cloudflare-platform-skill.md` (60 products, API refs)

**Capabilities**: Workers (deploy/update/list/tail), D1 (SQL/schema), KV (get/put/delete/list), R2 (buckets/objects), Pages (list/deploy), AI Gateway (logs/analytics), DNS (read/manage), Analytics (zone traffic)

<!-- AI-CONTEXT-END -->

## Auth Setup

OAuth 2.0 — no API tokens to manage. On first tool call, a browser window opens to `dash.cloudflare.com`; authorize once and the client stores the token.

**Claude Desktop** (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{ "mcpServers": { "cloudflare-api": { "url": "https://mcp.cloudflare.com/mcp" } } }
```

**OpenCode** (`~/.config/opencode/config.json`):

```json
{ "mcp": { "cloudflare-api": { "type": "remote", "url": "https://mcp.cloudflare.com/mcp" } } }
```

**Claude Code CLI**:

```bash
claude mcp add cloudflare-api --transport http https://mcp.cloudflare.com/mcp
```

> `--transport http` selects the MCP transport type (streamable HTTP), not the URL scheme — `http` is correct even though the endpoint uses HTTPS.

## Security Model

- **OAuth scopes**: Access matches your Cloudflare dashboard permissions
- **No secrets in config**: OAuth tokens stored by the MCP client in its secure token store
- **Revocation**: `dash.cloudflare.com` > My Profile > API Tokens > OAuth Apps
- **Least privilege**: For restricted scope, use a sub-account or scoped API token (see `services/hosting/cloudflare.md`)
- **Audit trail**: All MCP actions appear in Cloudflare's audit log under your account

## Usage Patterns

| Service | Example prompts |
|---------|----------------|
| **Workers** | `List all Workers` · `Show code for Worker "api-gateway"` · `Deploy ./src/worker.ts as "my-worker"` · `Tail logs for "my-worker"` |
| **D1** | `List D1 databases` · `Run SQL: SELECT * FROM users LIMIT 10 on "prod-db"` · `Show schema for "prod-db"` |
| **KV** | `List KV namespaces` · `Get key "config:feature-flags" from "APP_CONFIG"` · `List keys with prefix "user:" in "APP_DATA"` |
| **R2** | `List R2 buckets` · `List objects in "assets" with prefix "images/"` · `Upload ./dist/app.js to "releases" as "v1.2.3/app.js"` |
| **Pages** | `List Pages projects` · `Show deployments for "my-site"` · `Trigger deployment for "my-site"` |
| **AI Gateway** | `List AI Gateways` · `Show logs for "production"` · `Get analytics for last 24h` |
| **DNS** | `List DNS records for "example.com"` · `Add A record: api.example.com → 1.2.3.4 TTL 300` |

### Multi-step examples

```text
# Deploy Worker with bindings
Read ./src/worker.ts and deploy as "my-api". Bind to KV namespace "APP_DATA" and D1 "prod-db".

# Query D1
On "analytics" D1: SELECT date, count(*) as visits FROM page_views
WHERE date >= date('now', '-7 days') GROUP BY date ORDER BY date DESC

# Sync to R2
Upload all files in ./dist/ to R2 "static-assets" under prefix "v2.1.0/". List to confirm.
```

## Per-Agent Enablement

`cloudflare-api_*: true` in this subagent's frontmatter enables the MCP tools (disabled globally, enabled per-agent).

## Related Docs

- `services/hosting/cloudflare.md` — DNS/CDN API setup, token scoping, security
- `services/hosting/cloudflare-platform-skill.md` — Full platform reference (Workers, D1, R2, KV, Pages, AI, 60 products)
- `aidevops/mcp-integrations.md` — All MCP integrations overview and setup
- `configs/mcp-servers-config.json.txt` — Master MCP server config template
