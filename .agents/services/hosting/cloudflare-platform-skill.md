---
name: cloudflare-platform
description: "Cloudflare platform development guidance — patterns, gotchas, decision trees, SDK usage for Workers, Pages, KV, D1, R2, AI, Durable Objects, and 60+ products. Use when building or developing ON the Cloudflare platform. For managing Cloudflare resources (DNS, WAF, DDoS, R2 buckets, Workers deployments), use the Cloudflare Code Mode MCP server instead."
mode: subagent
imported_from: external
---

# Cloudflare Platform Skill

> **Not for API operations**: To manage/configure Cloudflare resources (DNS, zones, deployments) use the Cloudflare Code Mode MCP — see `../../tools/api/cloudflare-mcp.md`.

<!-- AI-CONTEXT-START -->

- **Scope**: Code that runs ON Cloudflare (Workers, Pages, D1, R2, KV, DO, AI, etc.)
- **Operations** (DNS, WAF, DDoS, R2 buckets, deployments): Code Mode MCP (`../../tools/api/cloudflare-mcp.md`)
- **Products**: Decision trees below → load `./cloudflare-platform-skill/<product>.md`

<!-- AI-CONTEXT-END -->

## Decision Trees

```text
Run code?
├─ Serverless functions at the edge → workers/
├─ Full-stack web app with Git deploys → pages/
├─ Stateful coordination/real-time → durable-objects/
├─ Long-running multi-step jobs → workflows/
├─ Run containers → containers/
├─ Multi-tenant (customers deploy code) → workers-for-platforms/
└─ Scheduled tasks (cron) → cron-triggers/

Store data?
├─ Key-value (config, sessions, cache) → kv/
├─ Relational SQL → d1/ (SQLite) or hyperdrive/ (existing Postgres/MySQL)
├─ Object/file storage (S3-compatible) → r2/
├─ Message queue (async processing) → queues/
├─ Vector embeddings (AI/semantic search) → vectorize/
├─ Strongly-consistent per-entity state → durable-objects/ (DO storage)
├─ Secrets management → secrets-store/
└─ Streaming ETL to R2 → pipelines/

Need AI?
├─ Run inference (LLMs, embeddings, images) → workers-ai/
├─ Vector database for RAG/search → vectorize/
├─ Build stateful AI agents → agents-sdk/
├─ Gateway for any AI provider (caching, routing) → ai-gateway/
└─ AI-powered search widget → ai-search/

Networking?
├─ Expose local service to internet → tunnel/
├─ TCP/UDP proxy (non-HTTP) → spectrum/
├─ WebRTC TURN server → turn/
├─ Private network connectivity → network-interconnect/
├─ Optimize routing → argo-smart-routing/
└─ Real-time video/audio → realtimekit/ or realtime-sfu/

Security?
├─ Web Application Firewall → waf/
├─ DDoS protection → ddos/
├─ Bot detection/management → bot-management/
├─ API protection → api-shield/
├─ CAPTCHA alternative → turnstile/
└─ Credential leak detection → waf/ (managed ruleset)

Media?
├─ Image optimization/transformation → images/
├─ Video streaming/encoding → stream/
├─ Browser automation/screenshots → browser-rendering/
└─ Third-party script management → zaraz/

IaC?
├─ Pulumi → pulumi/
├─ Terraform → terraform/
└─ Direct API → Code Mode MCP (tools/mcp/cloudflare-code-mode.md)
```

## Product Index

All paths: `./cloudflare-platform-skill/<file>.md`

**Compute & Runtime**: workers · pages · pages-functions · durable-objects · workflows · containers · workers-for-platforms · cron-triggers · tail-workers · snippets · smart-placement

**Storage & Data**: kv · d1 · r2 · queues · hyperdrive · do-storage · secrets-store · pipelines · r2-data-catalog · r2-sql

**AI & ML**: workers-ai · vectorize · agents-sdk · ai-gateway · ai-search

**Networking**: tunnel · spectrum · turn · network-interconnect · argo-smart-routing · workers-vpc

**Security**: waf · ddos · bot-management · api-shield · turnstile

**Media**: images · stream · browser-rendering · zaraz

**Real-Time**: realtimekit · realtime-sfu

**Dev Tools**: wrangler · miniflare · c3 · observability · analytics-engine · web-analytics · sandbox · workerd · workers-playground

**IaC**: pulumi · terraform · [API: `.agents/tools/mcp/cloudflare-code-mode.md`]

**Other**: email-routing · email-workers · static-assets · bindings · cache-reserve
