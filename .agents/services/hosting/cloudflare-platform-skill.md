---
name: cloudflare-platform
description: "Cloudflare platform development guidance — patterns, gotchas, decision trees, SDK usage for Workers, Pages, KV, D1, R2, AI, Durable Objects, and 60+ products. Use when building or developing ON the Cloudflare platform. For managing Cloudflare resources (DNS, WAF, DDoS, R2 buckets, Workers deployments), use the Cloudflare Code Mode MCP server instead."
mode: subagent
imported_from: external
---

# Cloudflare Platform Skill

Development guidance for building on Cloudflare — patterns, gotchas, decision trees, SDK usage for Workers, Pages, D1, R2, KV, Durable Objects, AI, and 60+ products.

> **Not for API operations**: To manage/configure Cloudflare resources (DNS, zones, deployments) use the Cloudflare Code Mode MCP — see `../../tools/api/cloudflare-mcp.md`.

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Scope**: Code that runs ON Cloudflare (Workers, Pages, D1, R2, KV, DO, AI, etc.)
- **Operations** (DNS, WAF, DDoS, R2 buckets, deployments): Code Mode MCP (`../../tools/api/cloudflare-mcp.md`)
- **Entry point**: Decision trees below → load `./cloudflare-platform-skill/<product>.md`
- **60+ products** indexed below with direct paths

<!-- AI-CONTEXT-END -->

## Routing: Operations vs Development

| Task | Tool |
|------|------|
| Manage DNS, zones, WAF, DDoS, firewall, R2 buckets, Workers deployments, Zero Trust, Access, Tunnels | Code Mode MCP (`tools/mcp/cloudflare-code-mode.md`) |
| Build Workers, configure wrangler.toml, debug runtime, understand architecture | This skill |

## File Structure

Each product directory may contain:

| File | Purpose |
|------|---------|
| `README.md` | Overview, when to use, getting started — **read first** |
| `patterns.md` | Common patterns, best practices |
| `gotchas.md` | Pitfalls, limitations, edge cases |

Single-file products consolidate everything in `README.md`. API/configuration details: use Code Mode MCP (live OpenAPI) — `api.md`/`configuration.md` files removed.

## Decision Trees

### "I need to run code"

```text
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

```text
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

```text
Need AI?
├─ Run inference (LLMs, embeddings, images) → workers-ai/
├─ Vector database for RAG/search → vectorize/
├─ Build stateful AI agents → agents-sdk/
├─ Gateway for any AI provider (caching, routing) → ai-gateway/
└─ AI-powered search widget → ai-search/
```

### "I need networking/connectivity"

```text
Need networking?
├─ Expose local service to internet → tunnel/
├─ TCP/UDP proxy (non-HTTP) → spectrum/
├─ WebRTC TURN server → turn/
├─ Private network connectivity → network-interconnect/
├─ Optimize routing → argo-smart-routing/
└─ Real-time video/audio → realtimekit/ or realtime-sfu/
```

### "I need security"

```text
Need security?
├─ Web Application Firewall → waf/
├─ DDoS protection → ddos/
├─ Bot detection/management → bot-management/
├─ API protection → api-shield/
├─ CAPTCHA alternative → turnstile/
└─ Credential leak detection → waf/ (managed ruleset)
```

### "I need media/content"

```text
Need media?
├─ Image optimization/transformation → images/
├─ Video streaming/encoding → stream/
├─ Browser automation/screenshots → browser-rendering/
└─ Third-party script management → zaraz/
```

### "I need infrastructure-as-code"

```text
Need IaC?
├─ Pulumi → pulumi/
├─ Terraform → terraform/
└─ Direct API → use Code Mode MCP (tools/mcp/cloudflare-code-mode.md)
```

## Product Index

### Compute & Runtime

| Product | Entry File |
|---------|------------|
| Workers | `./cloudflare-platform-skill/workers.md` |
| Pages | `./cloudflare-platform-skill/pages.md` |
| Pages Functions | `./cloudflare-platform-skill/pages-functions.md` |
| Durable Objects | `./cloudflare-platform-skill/durable-objects.md` |
| Workflows | `./cloudflare-platform-skill/workflows.md` |
| Containers | `./cloudflare-platform-skill/containers.md` |
| Workers for Platforms | `./cloudflare-platform-skill/workers-for-platforms.md` |
| Cron Triggers | `./cloudflare-platform-skill/cron-triggers.md` |
| Tail Workers | `./cloudflare-platform-skill/tail-workers.md` |
| Snippets | `./cloudflare-platform-skill/snippets.md` |
| Smart Placement | `./cloudflare-platform-skill/smart-placement.md` |

### Storage & Data

| Product | Entry File |
|---------|------------|
| KV | `./cloudflare-platform-skill/kv.md` |
| D1 | `./cloudflare-platform-skill/d1.md` |
| R2 | `./cloudflare-platform-skill/r2.md` |
| Queues | `./cloudflare-platform-skill/queues.md` |
| Hyperdrive | `./cloudflare-platform-skill/hyperdrive.md` |
| DO Storage | `./cloudflare-platform-skill/do-storage.md` |
| Secrets Store | `./cloudflare-platform-skill/secrets-store.md` |
| Pipelines | `./cloudflare-platform-skill/pipelines.md` |
| R2 Data Catalog | `./cloudflare-platform-skill/r2-data-catalog.md` |
| R2 SQL | `./cloudflare-platform-skill/r2-sql.md` |

### AI & Machine Learning

| Product | Entry File |
|---------|------------|
| Workers AI | `./cloudflare-platform-skill/workers-ai.md` |
| Vectorize | `./cloudflare-platform-skill/vectorize.md` |
| Agents SDK | `./cloudflare-platform-skill/agents-sdk.md` |
| AI Gateway | `./cloudflare-platform-skill/ai-gateway.md` |
| AI Search | `./cloudflare-platform-skill/ai-search.md` |

### Networking & Connectivity

| Product | Entry File |
|---------|------------|
| Tunnel | `./cloudflare-platform-skill/tunnel.md` |
| Spectrum | `./cloudflare-platform-skill/spectrum.md` |
| TURN | `./cloudflare-platform-skill/turn.md` |
| Network Interconnect | `./cloudflare-platform-skill/network-interconnect.md` |
| Argo Smart Routing | `./cloudflare-platform-skill/argo-smart-routing.md` |
| Workers VPC | `./cloudflare-platform-skill/workers-vpc.md` |

### Security

| Product | Entry File |
|---------|------------|
| WAF | `./cloudflare-platform-skill/waf.md` |
| DDoS Protection | `./cloudflare-platform-skill/ddos.md` |
| Bot Management | `./cloudflare-platform-skill/bot-management.md` |
| API Shield | `./cloudflare-platform-skill/api-shield.md` |
| Turnstile | `./cloudflare-platform-skill/turnstile.md` |

### Media & Content

| Product | Entry File |
|---------|------------|
| Images | `./cloudflare-platform-skill/images.md` |
| Stream | `./cloudflare-platform-skill/stream.md` |
| Browser Rendering | `./cloudflare-platform-skill/browser-rendering.md` |
| Zaraz | `./cloudflare-platform-skill/zaraz.md` |

### Real-Time Communication

| Product | Entry File |
|---------|------------|
| RealtimeKit | `./cloudflare-platform-skill/realtimekit.md` |
| Realtime SFU | `./cloudflare-platform-skill/realtime-sfu.md` |

### Developer Tools

| Product | Entry File |
|---------|------------|
| Wrangler | `./cloudflare-platform-skill/wrangler.md` |
| Miniflare | `./cloudflare-platform-skill/miniflare.md` |
| C3 | `./cloudflare-platform-skill/c3.md` |
| Observability | `./cloudflare-platform-skill/observability.md` |
| Analytics Engine | `./cloudflare-platform-skill/analytics-engine.md` |
| Web Analytics | `./cloudflare-platform-skill/web-analytics.md` |
| Sandbox | `./cloudflare-platform-skill/sandbox.md` |
| Workerd | `./cloudflare-platform-skill/workerd.md` |
| Workers Playground | `./cloudflare-platform-skill/workers-playground.md` |

### Infrastructure as Code

| Product | Entry File |
|---------|------------|
| Pulumi | `./cloudflare-platform-skill/pulumi.md` |
| Terraform | `./cloudflare-platform-skill/terraform.md` |
| API (Code Mode MCP) | `.agents/tools/mcp/cloudflare-code-mode.md` |

### Other Services

| Product | Entry File |
|---------|------------|
| Email Routing | `./cloudflare-platform-skill/email-routing.md` |
| Email Workers | `./cloudflare-platform-skill/email-workers.md` |
| Static Assets | `./cloudflare-platform-skill/static-assets.md` |
| Bindings | `./cloudflare-platform-skill/bindings.md` |
| Cache Reserve | `./cloudflare-platform-skill/cache-reserve.md` |
