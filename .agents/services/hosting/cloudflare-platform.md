---
description: "Cloudflare platform development guidance — patterns, gotchas, decision trees, SDK usage for Workers, Pages, KV, D1, R2, AI, Durable Objects, and 60+ products. Use when building or developing ON the Cloudflare platform. For managing Cloudflare resources (DNS, WAF, DDoS, R2 buckets, Workers deployments), use the Cloudflare Code Mode MCP server instead."
mode: subagent
imported_from: external
---
# cloudflare-platform

# Cloudflare Platform Skill

**Role**: Development guidance for building on the Cloudflare platform — patterns, gotchas, decision trees, SDK usage, and API references. This skill is for **developers writing code that runs on Cloudflare** (Workers, Pages, D1, R2, KV, Durable Objects, AI, etc.).

> **Not for API operations**: To manage, configure, or update Cloudflare resources (DNS records, zone settings, deployments) use the Cloudflare Code Mode MCP — see `tools/api/cloudflare-mcp.md`.

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Role**: Development guidance — patterns, gotchas, SDK usage, decision trees
- **Scope**: Building code that runs ON Cloudflare (Workers, Pages, D1, R2, KV, DO, AI, etc.)
- **Not for**: Managing/configuring CF resources → use `tools/api/cloudflare-mcp.md` (Code Mode MCP)
- **Entry point**: Use decision trees below to find the right product, then load `./references/<product>/README.md`
- **Reference format**: Multi-file (`patterns.md`, `gotchas.md`) or single-file; `api.md`/`configuration.md` superseded by Code Mode live OpenAPI queries
- **60+ products** indexed below with direct entry-point paths

<!-- AI-CONTEXT-END -->

## Routing: Operations vs Development

| Task | Tool |
|------|------|
| Manage DNS records, zones | Code Mode MCP |
| Configure WAF, DDoS, firewall rules | Code Mode MCP |
| Manage R2 buckets, Workers deployments | Code Mode MCP |
| Zero Trust, Access, Tunnel management | Code Mode MCP |
| Build a Worker (SDK, bindings, types) | This skill |
| Configure wrangler.toml, local dev | This skill |
| Debug Workers runtime issues | This skill |
| Understand product architecture, patterns | This skill |

Consolidated skill for building on the Cloudflare platform. Use decision trees below to find the right product, then load detailed references.

## How to Use This Skill

### Reference File Structure

Each product in `./references/<product>/` contains a `README.md` as the entry point, which may be structured in one of two ways:

**Multi-file format (3 files):**

| File | Purpose | When to Read |
|------|---------|--------------|
| `README.md` | Overview, when to use, getting started | **Always read first** |
| `patterns.md` | Common patterns, best practices | Implementation guidance |
| `gotchas.md` | Pitfalls, limitations, edge cases | Debugging, avoiding mistakes |

> **API & configuration details**: Use the Cloudflare Code Mode MCP (`tools/api/cloudflare-mcp.md`) for live OpenAPI spec queries — `api.md` and `configuration.md` files have been removed as they are superseded by Code Mode's real-time spec access.

**Single-file format:** All information consolidated in `README.md`.

### Reading Order

1. Start with `README.md`
2. Then read additional files relevant to your task (if multi-file format):
   - Implementation guidance → `patterns.md`
   - Troubleshooting → `gotchas.md`
   - API/configuration details → use Cloudflare Code Mode MCP (live OpenAPI)

### Example Paths

```
./references/workflows/README.md         # Start here for Workflows
./references/durable-objects/gotchas.md  # DO limitations
./references/workers-ai/README.md        # Single-file - all Workers AI docs
```

## Quick Decision Trees

### "I need to run code"

```
Need to run code?
├─ Serverless functions at the edge → workers/
├─ Full-stack web app with Git deploys → pages/
├─ Stateful coordination/real-time → durable-objects/
├─ Long-running multi-step jobs → workflows/
├─ Run containers → containers/
├─ Multi-tenant (customers deploy code) → workers-for-platforms/
└─ Scheduled tasks (cron) → cron-triggers/
```

### "I need to store data"

```
Need storage?
├─ Key-value (config, sessions, cache) → kv/
├─ Relational SQL → d1/ (SQLite) or hyperdrive/ (existing Postgres/MySQL)
├─ Object/file storage (S3-compatible) → r2/
├─ Message queue (async processing) → queues/
├─ Vector embeddings (AI/semantic search) → vectorize/
├─ Strongly-consistent per-entity state → durable-objects/ (DO storage)
├─ Secrets management → secrets-store/
└─ Streaming ETL to R2 → pipelines/
```

### "I need AI/ML"

```
Need AI?
├─ Run inference (LLMs, embeddings, images) → workers-ai/
├─ Vector database for RAG/search → vectorize/
├─ Build stateful AI agents → agents-sdk/
├─ Gateway for any AI provider (caching, routing) → ai-gateway/
└─ AI-powered search widget → ai-search/
```

### "I need networking/connectivity"

```
Need networking?
├─ Expose local service to internet → tunnel/
├─ TCP/UDP proxy (non-HTTP) → spectrum/
├─ WebRTC TURN server → turn/
├─ Private network connectivity → network-interconnect/
├─ Optimize routing → argo-smart-routing/
└─ Real-time video/audio → realtimekit/ or realtime-sfu/
```

### "I need security"

```
Need security?
├─ Web Application Firewall → waf/
├─ DDoS protection → ddos/
├─ Bot detection/management → bot-management/
├─ API protection → api-shield/
├─ CAPTCHA alternative → turnstile/
└─ Credential leak detection → waf/ (managed ruleset)
```

### "I need media/content"

```
Need media?
├─ Image optimization/transformation → images/
├─ Video streaming/encoding → stream/
├─ Browser automation/screenshots → browser-rendering/
└─ Third-party script management → zaraz/
```

### "I need infrastructure-as-code"

```
Need IaC?
├─ Pulumi → pulumi/
├─ Terraform → terraform/
└─ Direct API → use Code Mode MCP (tools/mcp/cloudflare-code-mode.md)
```

## Product Index

### Compute & Runtime

| Product | Entry File |
|---------|------------|
| Workers | `./references/workers/README.md` |
| Pages | `./references/pages/README.md` |
| Pages Functions | `./references/pages-functions/README.md` |
| Durable Objects | `./references/durable-objects/README.md` |
| Workflows | `./references/workflows/README.md` |
| Containers | `./references/containers/README.md` |
| Workers for Platforms | `./references/workers-for-platforms/README.md` |
| Cron Triggers | `./references/cron-triggers/README.md` |
| Tail Workers | `./references/tail-workers/README.md` |
| Snippets | `./references/snippets/README.md` |
| Smart Placement | `./references/smart-placement/README.md` |

### Storage & Data

| Product | Entry File |
|---------|------------|
| KV | `./references/kv/README.md` |
| D1 | `./references/d1/README.md` |
| R2 | `./references/r2/README.md` |
| Queues | `./references/queues/README.md` |
| Hyperdrive | `./references/hyperdrive/README.md` |
| DO Storage | `./references/do-storage/README.md` |
| Secrets Store | `./references/secrets-store/README.md` |
| Pipelines | `./references/pipelines/README.md` |
| R2 Data Catalog | `./references/r2-data-catalog/README.md` |
| R2 SQL | `./references/r2-sql/README.md` |

### AI & Machine Learning

| Product | Entry File |
|---------|------------|
| Workers AI | `./references/workers-ai/README.md` |
| Vectorize | `./references/vectorize/README.md` |
| Agents SDK | `./references/agents-sdk/README.md` |
| AI Gateway | `./references/ai-gateway/README.md` |
| AI Search | `./references/ai-search/README.md` |

### Networking & Connectivity

| Product | Entry File |
|---------|------------|
| Tunnel | `./references/tunnel/README.md` |
| Spectrum | `./references/spectrum/README.md` |
| TURN | `./references/turn/README.md` |
| Network Interconnect | `./references/network-interconnect/README.md` |
| Argo Smart Routing | `./references/argo-smart-routing/README.md` |
| Workers VPC | `./references/workers-vpc/README.md` |

### Security

| Product | Entry File |
|---------|------------|
| WAF | `./references/waf/README.md` |
| DDoS Protection | `./references/ddos/README.md` |
| Bot Management | `./references/bot-management/README.md` |
| API Shield | `./references/api-shield/README.md` |
| Turnstile | `./references/turnstile/README.md` |

### Media & Content

| Product | Entry File |
|---------|------------|
| Images | `./references/images/README.md` |
| Stream | `./references/stream/README.md` |
| Browser Rendering | `./references/browser-rendering/README.md` |
| Zaraz | `./references/zaraz/README.md` |

### Real-Time Communication

| Product | Entry File |
|---------|------------|
| RealtimeKit | `./references/realtimekit/README.md` |
| Realtime SFU | `./references/realtime-sfu/README.md` |

### Developer Tools

| Product | Entry File |
|---------|------------|
| Wrangler | `./references/wrangler/README.md` |
| Miniflare | `./references/miniflare/README.md` |
| C3 | `./references/c3/README.md` |
| Observability | `./references/observability/README.md` |
| Analytics Engine | `./references/analytics-engine/README.md` |
| Web Analytics | `./references/web-analytics/README.md` |
| Sandbox | `./references/sandbox/README.md` |
| Workerd | `./references/workerd/README.md` |
| Workers Playground | `./references/workers-playground/README.md` |

### Infrastructure as Code

| Product | Entry File |
|---------|------------|
| Pulumi | `./references/pulumi/README.md` |
| Terraform | `./references/terraform/README.md` |
| API (Code Mode MCP) | `.agents/tools/mcp/cloudflare-code-mode.md` |

### Other Services

| Product | Entry File |
|---------|------------|
| Email Routing | `./references/email-routing/README.md` |
| Email Workers | `./references/email-workers/README.md` |
| Static Assets | `./references/static-assets/README.md` |
| Bindings | `./references/bindings/README.md` |
| Cache Reserve | `./references/cache-reserve/README.md` |
