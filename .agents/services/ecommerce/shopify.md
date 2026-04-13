---
description: Shopify store management — schema-aware GraphQL, Liquid template validation, Admin API, content management via MCP
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  shopify-dev-mcp_*: true
  # TODO(permission-migration, anomalyco/opencode#6892): when MCP wildcard gating lands,
  # migrate to `permission: shopify-dev-mcp: allow` and remove shopify-dev-mcp_* above.
mcp:
  - shopify-dev-mcp
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Shopify Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **MCP**: `shopify-dev-mcp` — schema-aware GraphQL, Liquid validation, Admin API execution
- **Tool prefix**: `shopify-dev-mcp_*`
- **Prerequisites**: Node 18+, Shopify CLI 3.93.0+ (`npm install -g @shopify/cli@latest`)
- **Auth**: Browser OAuth via `shopify store auth` — no stored tokens
- **Config template**: `configs/mcp-templates/shopify-dev-mcp-config.json.txt`
- **Setup**: `setup-mcp-integrations.sh shopify-dev-mcp`

## Activation

Invoked with `@shopify`. The `shopify-dev-mcp` server lazy-loads on first tool call (`eager: false` in plugin registry) — no context bloat for non-Shopify sessions. Tool calls gated: `shopify-dev-mcp_*: false` globally, `true` only for this agent.

**Headless workers**: If `shopify-dev-mcp` tools are absent from the session tool list, exit BLOCKED:
`BLOCKED: Required MCP shopify-dev-mcp not available. Ensure aidevops plugin is loaded and restart OpenCode.`

## Capabilities

| Task | Approach |
|------|----------|
| Validate Liquid templates | MCP schema validation before push |
| Search Admin GraphQL schema | Schema-aware field/mutation lookup |
| Execute Admin GraphQL | `shopify store execute` via MCP |
| Blog/article management | Full content CRUD via Admin API |
| Pages, redirects, navigation | Content management surface |
| Metafields, SEO metadata | Structured data management |

> **Why MCP over CLI**: `shopify store execute` (CLI) is raw GraphQL — no schema awareness, no field validation. MCP guides correct queries and catches schema errors before hitting the API. CLI is only appropriate for theme file operations (`themeFilesUpsert`) and simple product/order reads where the schema is stable and well-known.

## Repo-Level Skills

Install per-repo from the Shopify AI Toolkit (not framework-level):

```bash
npx @shopify/shopify-ai-toolkit@latest add shopify-admin
npx @shopify/shopify-ai-toolkit@latest add shopify-liquid
npx @shopify/shopify-ai-toolkit@latest add shopify-polaris
```

Available: `shopify-admin`, `shopify-admin-execution`, `shopify-liquid`, `shopify-polaris`, `shopify-app-bridge`

## repos.json Integration

Tag Shopify repos with `"platform": "shopify"` to document intent (auto-enable not yet implemented at dispatch layer — invoke `@shopify` explicitly):

```json
{
  "slug": "owner/my-shopify-store",
  "path": "~/Git/my-shopify-store",
  "platform": "shopify",
  "pulse": true
}
```

<!-- AI-CONTEXT-END -->
