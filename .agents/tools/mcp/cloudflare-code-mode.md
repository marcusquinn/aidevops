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

**MCP server URL**: `https://mcp.cloudflare.com/mcp` | **Config template**: `configs/mcp-templates/cloudflare-api.json`

## When to Use This (vs cloudflare-platform skill)

- **Code Mode MCP** (`search` + `execute`): Manage DNS, zones, WAF, DDoS, firewall rules, R2 buckets, Workers deployments, Zero Trust, Access policies
- **`cloudflare-platform-skill`**: Build Workers (SDK, bindings, patterns), configure wrangler.toml, local dev, debug runtime issues, understand product architecture

## Setup

### Interactive (OAuth 2.1)

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

```text
Authorization: Bearer <your-cloudflare-api-token>
```

See `services/hosting/cloudflare.md` for token creation guidance.

## Tools

Both tools run in a **sandboxed V8 isolate** (no filesystem, no env var leakage, external fetches disabled by default). OAuth 2.1 downscopes the token to user-approved permissions only.

### `search(code)`

Searches the Cloudflare OpenAPI spec. The `spec` object contains the full spec with all `$refs` pre-resolved. Write JavaScript to filter endpoints. The full spec never enters the model context; only filtered results do.

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

Executes JavaScript against the Cloudflare API. The sandbox provides a `cloudflare.request()` client for authenticated API calls.

```javascript
// List DNS records (simple GET)
async () => {
  const zoneId = "<YOUR_ZONE_ID>";
  const res = await cloudflare.request({
    method: "GET",
    path: `/zones/${zoneId}/dns_records`
  });
  return res.result;
}
```

```javascript
// Enable managed WAF ruleset (PUT with body)
async () => {
  const zoneId = "<YOUR_ZONE_ID>";
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

```javascript
// Chain multiple API calls in one execution
async () => {
  const zoneId = "<YOUR_ZONE_ID>";
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

```javascript
// List R2 buckets (account-level endpoint)
async () => {
  const accountId = "<YOUR_ACCOUNT_ID>";
  const res = await cloudflare.request({
    method: "GET",
    path: `/accounts/${accountId}/r2/buckets`
  });
  return res.result;
}
```

## References

- Blog post: https://blog.cloudflare.com/code-mode-mcp/
- GitHub: https://github.com/cloudflare/mcp-server-cloudflare
- Cloudflare API docs: https://developers.cloudflare.com/api/
- Code Mode SDK (open source): https://github.com/cloudflare/agents/tree/main/packages/codemode
