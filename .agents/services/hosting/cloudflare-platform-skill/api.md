---
name: api
description: "Cloudflare api: product reference"
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudflare API Integration

Guide for working with Cloudflare's REST API - authentication, SDK usage, common patterns, and troubleshooting.

## Quick Decision Tree

```text
How are you calling the Cloudflare API?
├─ From Workers runtime → Use bindings, not REST API (see bindings.md)
├─ Server-side (Node/Python/Go) → Official SDK (see below)
├─ CLI/scripts → Wrangler or curl (see wrangler.md)
├─ Infrastructure-as-code → Use the Cloudflare Terraform or Pulumi provider's own current docs (not mirrored here)
└─ One-off requests → curl examples (see below)
```

## SDK Selection

| Language | Package | Best For | Default Retries |
|----------|---------|----------|-----------------|
| TypeScript | `cloudflare` | Node.js, Bun, Next.js, Workers | 2 |
| Python | `cloudflare` | FastAPI, Django, scripts | 2 |
| Go | `cloudflare-go/v4` | CLI tools, microservices | 10 |

All SDKs are Stainless-generated from OpenAPI spec (consistent APIs).

## Authentication Methods

| Method | Security | Use Case | Scope |
|--------|----------|----------|-------|
| **API Token** ✓ | Scoped, rotatable | Production | Per-zone or account |
| API Key + Email | Full account access | Legacy only | Everything |
| User Service Key | Limited | Origin CA certs only | Origin CA |

**Always use API tokens** for new projects.

## Rate Limits

| Limit | Value |
|-------|-------|
| Per user/token | 1200 requests / 5 minutes |
| Per IP | 200 requests / second |
| GraphQL | 320 / 5 minutes (cost-based) |

## Reading Order

| Task | Files to Read |
|------|---------------|
| Initialize SDK client | api.md |
| Configure auth/timeout/retry | configuration.md |
| Find usage patterns | patterns.md |
| Debug errors/rate limits | gotchas.md |
| Product-specific APIs | [Workers docs](https://developers.cloudflare.com/workers/), ../r2/, ../kv/, etc. |

## In This Reference

- **This file** - SDK client initialization, environment variables, pagination, error handling, examples
- **[api-gotchas.md](api-gotchas.md)** - Rate limits, SDK-specific issues, troubleshooting

## See Also

- [Cloudflare API Docs](https://developers.cloudflare.com/api/)
- [Bindings Reference](bindings.md) - Workers runtime bindings (preferred over REST API)
- [Wrangler Reference](https://developers.cloudflare.com/workers/wrangler/) - CLI tool for Cloudflare development
- [GraphQL Analytics API Reference](graphql-api.md) - Analytics data via GraphQL (separate endpoint from REST API)
