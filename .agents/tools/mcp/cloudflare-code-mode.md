---
description: "Cloudflare Code Mode MCP server — full Cloudflare API coverage (2,500+ endpoints) via 2 tools (search + execute) in ~1,000 tokens. Use for all Cloudflare operations: DNS, WAF, DDoS, R2 management, Workers management, Zero Trust, etc."
mode: subagent
tools:
  bash: true
  webfetch: true
mcp_servers:
  - cloudflare-api
---

# Cloudflare Code Mode MCP

## What It Is

The Cloudflare Code Mode MCP server provides access to the **entire Cloudflare API** (2,500+ endpoints) via just **two tools** consuming ~1,000 tokens — a 99.9% reduction vs a native MCP server (which would require 1.17M tokens).

**MCP server URL**: `https://mcp.cloudflare.com/mcp`

**Config template**: `configs/mcp-templates/cloudflare-api.json`

## When to Use This (vs cloudflare-platform skill)

| Intent | Use |
|--------|-----|
| Manage DNS records, zones, WAF rules | Code Mode MCP (`search` + `execute`) |
| Configure DDoS protection, firewall rules | Code Mode MCP |
| Manage R2 buckets, Workers deployments | Code Mode MCP |
| Zero Trust, Access policies | Code Mode MCP |
| Build a Worker (SDK, bindings, patterns) | `cloudflare-platform` skill |
| Configure wrangler.toml, local dev | `cloudflare-platform` skill |
| Debug Workers runtime issues | `cloudflare-platform` skill |
| Understand Cloudflare product architecture | `cloudflare-platform` skill |

## Setup

### Interactive (OAuth 2.1)

Add to your MCP client config:

```json
{
  "mcpServers": {
    "cloudflare-api": {
      "url": "https://mcp.cloudflare.com/mcp"
    }
  }
}
```

On first connection, you are redirected to Cloudflare to authorize and select permissions. The token is downscoped to only the capabilities you grant.

### CI/CD (API Token)

Create a Cloudflare API token with required permissions, then pass as bearer token:

```bash
# Authorization header
Authorization: Bearer <your-cloudflare-api-token>
```

See `services/hosting/cloudflare.md` for token creation guidance.

## Tools

### `search(code)`

Searches the Cloudflare OpenAPI spec. The `spec` object contains the full spec with all `$refs` pre-resolved. Write JavaScript to filter endpoints.

```javascript
// Find WAF and ruleset endpoints for a zone
async () => {
  const results = [];
  for (const [path, methods] of Object.entries(spec.paths)) {
    if (path.includes('/zones/') &&
        (path.includes('firewall/waf') || path.includes('rulesets'))) {
      for (const [method, op] of Object.entries(methods)) {
        results.push({ method: method.toUpperCase(), path, summary: op.summary });
      }
    }
  }
  return results;
}
```

```javascript
// Inspect a specific endpoint's schema
async () => {
  const op = spec.paths['/zones/{zone_id}/rulesets']?.get;
  const items = op?.responses?.['200']?.content?.['application/json']?.schema;
  const props = items?.allOf?.[1]?.properties?.result?.items?.allOf?.[1]?.properties;
  return { phases: props?.phase?.enum };
}
```

### `execute(code)`

Executes JavaScript against the Cloudflare API. The sandbox provides a `cloudflare.request()` client for authenticated API calls. Runs in a V8 isolate (no filesystem, no env var leakage, external fetches disabled by default).

```javascript
// List rulesets on a zone
async () => {
  const response = await cloudflare.request({
    method: "GET",
    path: `/zones/${zoneId}/rulesets`
  });
  return response.result.map(rs => ({ name: rs.name, phase: rs.phase, kind: rs.kind }));
}
```

```javascript
// Chain multiple API calls in one execution
async () => {
  const ddos = await cloudflare.request({
    method: "GET",
    path: `/zones/${zoneId}/rulesets/phases/ddos_l7/entrypoint`
  });
  const waf = await cloudflare.request({
    method: "GET",
    path: `/zones/${zoneId}/rulesets/phases/http_request_firewall_managed/entrypoint`
  });
  return { ddos: ddos.result, waf: waf.result };
}
```

## How Code Mode Works

1. **`search()`** — agent writes JS against the OpenAPI spec object to discover endpoints. The full spec never enters the model context; only the filtered results do.
2. **`execute()`** — agent writes JS that calls `cloudflare.request()`. Multiple API calls can be chained in a single execution. Results are returned directly.
3. Both tools run in a **Dynamic Worker isolate** (sandboxed V8, no file system, no env var leakage).
4. **OAuth 2.1** downscopes the token to user-approved permissions only.

## Common Operations

### DNS Management

```javascript
// search: find DNS record endpoints
async () => {
  return Object.entries(spec.paths)
    .filter(([path]) => path.includes('/dns_records'))
    .map(([path, methods]) => ({
      path,
      methods: Object.keys(methods)
    }));
}

// execute: list DNS records
async () => {
  const res = await cloudflare.request({
    method: "GET",
    path: `/zones/${zoneId}/dns_records`
  });
  return res.result;
}
```

### WAF / Firewall Rules

```javascript
// execute: enable managed WAF ruleset
async () => {
  return await cloudflare.request({
    method: "PUT",
    path: `/zones/${zoneId}/rulesets/phases/http_request_firewall_managed/entrypoint`,
    body: {
      rules: [{
        action: "execute",
        expression: "true",
        action_parameters: { id: "efb7b8c949ac4650a09736fc376e9aee" }
      }]
    }
  });
}
```

### R2 Bucket Management

```javascript
// execute: list R2 buckets
async () => {
  const res = await cloudflare.request({
    method: "GET",
    path: `/accounts/${accountId}/r2/buckets`
  });
  return res.result;
}
```

## References

- Blog post: https://blog.cloudflare.com/code-mode-mcp/
- GitHub: https://github.com/cloudflare/mcp
- Cloudflare API docs: https://developers.cloudflare.com/api/
- Code Mode SDK (open source): https://github.com/cloudflare/agents/tree/main/packages/codemode
