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
- **Platform docs**: `services/hosting/cloudflare-platform.md` (60 products, API refs)

**Capabilities**:
- Workers: deploy, update, list, tail logs
- D1: execute SQL, inspect schema, list databases
- KV: get/put/delete/list keys across namespaces
- R2: list buckets, get/put/delete objects
- Pages: list projects, trigger deployments
- AI Gateway: view logs and analytics
- DNS: read/manage records
- Analytics: zone traffic and performance data

<!-- AI-CONTEXT-END -->

## Auth Setup

Cloudflare Code Mode MCP uses OAuth 2.0 — no API tokens to manage manually.

### First-Time Connection

1. Add the server config (see below)
2. Start your MCP client (Claude Desktop, OpenCode, etc.)
3. On first tool call, a browser window opens to `dash.cloudflare.com`
4. Authorize the OAuth app for your account
5. The client stores the token — subsequent connections are seamless

### Config

**Claude Desktop** (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "cloudflare-api": {
      "url": "https://mcp.cloudflare.com/mcp"
    }
  }
}
```

**OpenCode** (`~/.config/opencode/config.json`):

```json
{
  "mcp": {
    "cloudflare-api": {
      "type": "remote",
      "url": "https://mcp.cloudflare.com/mcp"
    }
  }
}
```

**Claude Code CLI**:

```bash
claude mcp add cloudflare-api --transport http https://mcp.cloudflare.com/mcp
```

## Security Model

- **OAuth scopes**: Tied to your Cloudflare account — access matches your dashboard permissions
- **No secrets in config**: The URL contains no credentials; OAuth tokens are stored by the MCP client in its secure token store
- **Revocation**: Revoke access at `dash.cloudflare.com` > My Profile > API Tokens > OAuth Apps
- **Least privilege**: If you need to restrict scope, use a sub-account or create a scoped API token instead (see `services/hosting/cloudflare.md`)
- **Audit trail**: All MCP actions appear in Cloudflare's audit log under your account

## Search Patterns

Use these patterns when asking the AI to interact with Cloudflare resources:

### Workers

```
List all Workers in my account
Show the code for Worker named "api-gateway"
Deploy the Worker script at ./src/worker.ts to "my-worker"
Tail logs for Worker "my-worker"
```

### D1 (SQLite)

```
List all D1 databases
Run SQL: SELECT * FROM users LIMIT 10 on database "prod-db"
Show the schema for D1 database "prod-db"
Create a table in D1: CREATE TABLE events (id INTEGER PRIMARY KEY, name TEXT)
```

### KV (Key-Value)

```
List all KV namespaces
Get the value of key "config:feature-flags" from namespace "APP_CONFIG"
Put key "session:abc123" with value "..." in namespace "SESSIONS"
List all keys with prefix "user:" in namespace "APP_DATA"
Delete key "cache:stale" from namespace "CACHE"
```

### R2 (Object Storage)

```
List all R2 buckets
List objects in bucket "assets" with prefix "images/"
Get object "images/logo.png" from bucket "assets"
Upload file ./dist/app.js to bucket "releases" as "v1.2.3/app.js"
Delete object "tmp/old-file.txt" from bucket "assets"
```

### Pages

```
List all Pages projects
Show deployments for Pages project "my-site"
Trigger a new deployment for Pages project "my-site"
```

### AI Gateway

```
List all AI Gateways
Show recent logs for AI Gateway "production"
Get analytics for AI Gateway "production" for the last 24 hours
```

### DNS

```
List DNS records for zone "example.com"
Add A record: api.example.com → 1.2.3.4 with TTL 300
Delete CNAME record "www" from zone "example.com"
```

## Execute Patterns

Common end-to-end workflows:

### Deploy a Worker

```
Read ./src/worker.ts and deploy it as a Cloudflare Worker named "my-api".
Bind it to the KV namespace "APP_DATA" and D1 database "prod-db".
```

### Query D1 and return results

```
On D1 database "analytics", run:
SELECT date, count(*) as visits FROM page_views
WHERE date >= date('now', '-7 days')
GROUP BY date ORDER BY date DESC
```

### Sync local files to R2

```
Upload all files in ./dist/ to R2 bucket "static-assets" under prefix "v2.1.0/".
List the uploaded objects to confirm.
```

### Inspect KV namespace

```
List all keys in KV namespace "FEATURE_FLAGS".
For each key, get its value and show me the full config.
```

## Per-Agent Enablement

This subagent has `cloudflare-api_*: true` in its tools frontmatter. The MCP tools are disabled globally and enabled only when this subagent is active.

To invoke this subagent: reference `tools/api/cloudflare-mcp.md` in your agent's tools section, or ask the AI to use Cloudflare MCP tools directly when this subagent is loaded.

## Related Docs

- `services/hosting/cloudflare.md` — DNS/CDN API setup, token scoping, security
- `services/hosting/cloudflare-platform.md` — Full platform reference (Workers, D1, R2, KV, Pages, AI, 60 products)
- `aidevops/mcp-integrations.md` — All MCP integrations overview and setup
- `configs/mcp-servers-config.json.txt` — Master MCP server config template
