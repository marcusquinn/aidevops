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

**Interactive (OAuth 2.1):** Add to MCP config — on first connection, Cloudflare prompts for authorization with downscoped permissions:

```json
{ "mcpServers": { "cloudflare-api": { "url": "https://mcp.cloudflare.com/mcp" } } }
```

**CI/CD:** Create a Cloudflare API token (see `services/hosting/cloudflare.md`), pass as `Authorization: Bearer <token>`.

## Tools

Both tools run in a **sandboxed V8 isolate** (no filesystem, no env var leakage, external fetches disabled). OAuth 2.1 downscopes the token to user-approved permissions only.

### `search(code)`

Searches the Cloudflare OpenAPI spec. The `spec` object has all `$refs` pre-resolved. Write JavaScript to filter endpoints — the full spec never enters model context, only filtered results.

```javascript
// Find endpoints matching a path pattern
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

### `execute(code)`

Executes JavaScript against the Cloudflare API via `cloudflare.request()`. Zone-level endpoints use `/zones/{zone_id}/...`, account-level use `/accounts/{account_id}/...`.

```javascript
// Simple GET — list DNS records
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
// PUT with body — enable managed WAF ruleset
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

Chain multiple `cloudflare.request()` calls in a single `execute` invocation to batch related operations (e.g., fetching DDoS + WAF rulesets together).

## References

- Blog post: https://blog.cloudflare.com/code-mode-mcp/
- GitHub: https://github.com/cloudflare/mcp-server-cloudflare
- Cloudflare API docs: https://developers.cloudflare.com/api/
- Code Mode SDK (open source): https://github.com/cloudflare/agents/tree/main/packages/codemode
