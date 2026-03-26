---
description: Hosting platform decision guide — Fly.io, Daytona, Coolify, Cloudron, Vercel comparison
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: false
  grep: false
  webfetch: false
  task: false
---

# Hosting Platform Decision Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

| Platform | Model | Best for | Pricing model |
|----------|-------|----------|---------------|
| **Fly.io** | Managed PaaS (Firecracker VMs) | Global apps, AI sandboxes, always-on | Per-second compute + storage |
| **Daytona** | Cloud sandbox (SaaS) | AI agent code execution, ephemeral CI | Per-second, per-resource |
| **Coolify** | Self-hosted PaaS | Cost control, data sovereignty, Docker apps | Server cost only (self-hosted) |
| **Cloudron** | Self-hosted app platform | Off-the-shelf app hosting, non-technical teams | Server cost + optional subscription |
| **Vercel** | Serverless/Edge PaaS | Frontend, Next.js, JAMstack, serverless functions | Invocation + bandwidth |

**Platform docs**: `fly-io.md` | `daytona.md` | `coolify.md` | `cloudron-app-packaging.md` | `vercel.md`

<!-- AI-CONTEXT-END -->

This guide compares hosting platforms across the dimensions that matter for cost and architecture decisions. Pricing figures are approximate — verify at each platform's pricing page before committing.

**Pricing sources** (check for current rates):

- Fly.io: https://fly.io/docs/about/pricing/ and https://fly.io/calculator
- Daytona: https://www.daytona.io/pricing
- Coolify: https://coolify.io/pricing (self-hosted is free; cloud managed has a fee)
- Cloudron: https://www.cloudron.io/pricing.html
- Vercel: https://vercel.com/pricing

---

## Platform Overview

### Fly.io

Managed PaaS running apps on Firecracker micro-VMs (Fly Machines) across 30+ regions with anycast routing. Billed per second of active compute time. Auto-stop/start eliminates idle costs.

- **Deployment model**: Docker image → Fly Machine (Firecracker micro-VM)
- **Networking**: Global anycast — traffic routes to nearest healthy region automatically
- **Persistence**: NVMe volumes (region-specific), Fly Postgres, Upstash Redis
- **AI sandboxes**: Sprites — isolated Fly Machines for untrusted agent code
- **Self-hosted option**: No
- **Free tier**: 3 shared-cpu-1x VMs (256 MB), 3 GB storage, 160 GB transfer

### Daytona

Cloud sandbox platform optimised for AI agent workflows. Each sandbox is a fully isolated Linux environment (gVisor kernel-level isolation) with per-second billing and stateful snapshots. Not a traditional app host — designed for ephemeral code execution and dev environments.

- **Deployment model**: API/SDK → isolated sandbox (gVisor)
- **Networking**: Private by default; optional public port exposure
- **Persistence**: Stateful snapshots (stop/resume without data loss); disk billed when stopped
- **AI sandboxes**: Core use case — safe execution of LLM-generated code
- **Self-hosted option**: No (SaaS only)
- **Free tier**: Check https://www.daytona.io/pricing (credits available)

### Coolify

Open-source, self-hosted PaaS. You run Coolify on your own server (VPS, bare metal, cloud VM). Coolify manages Docker deployments, SSL, databases, and Git webhooks. You pay only for the server.

- **Deployment model**: Git push → Docker container on your server
- **Networking**: Your server's network; Coolify manages reverse proxy + SSL
- **Persistence**: Docker volumes on your server; database containers
- **AI sandboxes**: Not designed for this — use Fly.io Sprites or Daytona
- **Self-hosted option**: Yes (this is the product)
- **Free tier**: Coolify software is free (AGPL); server cost is yours

### Cloudron

Self-hosted app platform focused on one-click installation of pre-packaged apps (WordPress, Nextcloud, Gitea, etc.). Manages updates, backups, SSO, and SSL automatically. Requires packaging custom apps via CloudronManifest.json + Dockerfile.

- **Deployment model**: Cloudron app packages → managed containers on your server
- **Networking**: Your server; Cloudron manages nginx + Let's Encrypt
- **Persistence**: `/app/data` volumes managed by Cloudron; addon databases (MySQL, PostgreSQL, Redis)
- **AI sandboxes**: Not designed for this
- **Self-hosted option**: Yes (this is the product)
- **Free tier**: Free for up to 2 apps; paid plans for more

### Vercel

Serverless/Edge PaaS optimised for frontend frameworks (Next.js, React, Vue) and serverless functions. Deploys to a global CDN edge network. Not suitable for long-running processes or stateful workloads.

- **Deployment model**: Git push → serverless functions + static assets on Edge CDN
- **Networking**: Global CDN (100+ PoPs); Edge Functions run at the edge
- **Persistence**: No built-in storage — use external DB (PlanetScale, Neon, Supabase, etc.)
- **AI sandboxes**: Not designed for this
- **Self-hosted option**: No (Enterprise can use custom infrastructure)
- **Free tier**: Generous — 100 GB bandwidth, 6,000 function invocations/day

---

## Feature Comparison Matrix

| Dimension | Fly.io | Daytona | Coolify | Cloudron | Vercel |
|-----------|--------|---------|---------|----------|--------|
| **Deployment type** | Managed PaaS | Cloud sandbox | Self-hosted PaaS | Self-hosted app platform | Serverless/Edge PaaS |
| **Compute model** | Firecracker micro-VMs | gVisor sandboxes | Docker containers | Docker containers | Serverless functions |
| **Always-on support** | Yes | Yes (stop/start) | Yes | Yes | No (serverless) |
| **Auto-stop/start** | Yes (built-in) | Yes (manual stop) | No | No | N/A (serverless) |
| **Cold start latency** | ~200–500 ms (auto-stop) | ~90 ms | None (always-on) | None (always-on) | ~50–200 ms (Edge) |
| **Global distribution** | Yes (30+ regions, anycast) | No (single region) | No (your server) | No (your server) | Yes (100+ PoPs) |
| **Persistent volumes** | Yes (NVMe, region-specific) | Yes (snapshots) | Yes (Docker volumes) | Yes (/app/data) | No (external only) |
| **Managed databases** | Fly Postgres, Upstash Redis | No | PostgreSQL, MySQL, MongoDB, Redis | MySQL, PostgreSQL, Redis | No (external only) |
| **AI agent sandboxes** | Yes (Sprites) | Yes (core use case) | No | No | No |
| **GPU support** | No | Yes (A100, H100, L40S) | No | No | No |
| **Self-hosted option** | No | No | Yes | Yes | No |
| **Data sovereignty** | No (Fly.io infra) | No (Daytona infra) | Yes (your server) | Yes (your server) | No (Vercel infra) |
| **App marketplace** | No | No | No | Yes (200+ apps) | No |
| **SSO/LDAP** | No | No | No | Yes (built-in) | No |
| **Automatic SSL** | Yes | N/A | Yes (Let's Encrypt) | Yes (Let's Encrypt) | Yes |
| **Billing model** | Per-second compute + storage | Per-second, per-resource | Server cost only | Server cost + optional sub | Invocations + bandwidth |
| **Free tier** | Yes (3 VMs) | Yes (credits) | Yes (software free) | Yes (2 apps) | Yes (generous) |

---

## Pricing Analysis

### Compute Pricing Reference

**Fly.io** (shared CPU, approximate):

| Machine | vCPU | RAM | Always-on/mo | Per-hour |
|---------|------|-----|-------------|---------|
| shared-cpu-1x | 1 shared | 256 MB | ~$1.94 | ~$0.0027 |
| shared-cpu-2x | 2 shared | 512 MB | ~$3.88 | ~$0.0054 |
| shared-cpu-4x | 4 shared | 1 GB | ~$7.76 | ~$0.0108 |
| performance-1x | 1 dedicated | 2 GB | ~$31.00 | ~$0.0430 |
| performance-2x | 2 dedicated | 4 GB | ~$62.00 | ~$0.0860 |
| performance-4x | 4 dedicated | 8 GB | ~$124.00 | ~$0.1720 |

Storage: ~$0.15/GB/month (volumes). Bandwidth: ~$0.02/GB after 160 GB free.

**Daytona** (per-second, per-resource — check https://www.daytona.io/pricing for current rates):

Billing is per-second for active vCPU + RAM + disk. When stopped, only disk is billed. Exact per-second rates vary — use the pricing page calculator. For reference, Grok's analysis (March 2026) estimated ~$48–50/month for always-on 1 vCPU/1 GB vs Fly.io's ~$5.92/month for the same spec — Daytona is significantly more expensive for always-on workloads but competitive for bursty/ephemeral use.

**Coolify** (self-hosted — server cost only):

You pay for the VPS/server. Coolify software is free (AGPL). Typical server costs:

| Provider | Spec | Monthly |
|----------|------|---------|
| Hetzner CX22 | 2 vCPU, 4 GB RAM | ~€4.35 |
| Hetzner CX32 | 4 vCPU, 8 GB RAM | ~€8.70 |
| DigitalOcean Basic | 2 vCPU, 4 GB RAM | ~$24 |
| Vultr | 2 vCPU, 4 GB RAM | ~$24 |

Coolify Cloud (managed, no self-hosting): check https://coolify.io/pricing.

**Cloudron** (self-hosted — server cost + optional subscription):

- Free: up to 2 apps
- Subscription: ~$15/month (unlimited apps, priority support)
- Server cost: same as Coolify above

**Vercel** (invocation-based):

| Plan | Monthly | Bandwidth | Function invocations |
|------|---------|-----------|---------------------|
| Hobby | Free | 100 GB | 100K/day |
| Pro | $20/user | 1 TB | 1M/day |
| Enterprise | Custom | Custom | Custom |

Edge Functions: ~$0.60/million invocations (after free tier). Serverless Functions: ~$0.18/GB-hour compute.

---

## Worked Cost Examples

Three workload profiles to illustrate real-world costs.

### Profile 1: Always-On Web App (1 vCPU / 1 GB RAM, 24/7)

A backend API or web app that must always be running with no cold starts.

| Platform | Monthly cost | Notes |
|----------|-------------|-------|
| **Fly.io** | ~$5.92 | shared-cpu-4x (4 shared vCPU, 1 GB RAM) + min_machines_running=1 |
| **Daytona** | ~$48–50 | Per-second billing for always-on; significantly more expensive than Fly.io for this profile |
| **Coolify** | ~€4–8 | Hetzner CX22/CX32 server; Coolify software free; best value for always-on |
| **Cloudron** | ~€4–8 + $15 sub | Same server cost + Cloudron subscription for >2 apps |
| **Vercel** | Not suitable | No always-on compute; serverless only |

**Winner for always-on**: Coolify on Hetzner (~€4–8/mo) if you can manage a server. Fly.io (~$5.92/mo) if you want managed infrastructure with no ops overhead.

### Profile 2: Bursty AI Agent Sandbox (1 vCPU / 1 GB RAM, ~4 hours/day active)

An AI agent that executes code in isolated sandboxes, active ~4 hours/day (120 hours/month).

| Platform | Monthly cost | Notes |
|----------|-------------|-------|
| **Fly.io** | ~$0.65–1.30 | Auto-stop; ~120h active × $0.0108/hr (shared-cpu-4x) = ~$1.30; Sprites for isolation |
| **Daytona** | ~$6–8 | Per-second billing; 120h active × per-second rate; gVisor isolation; GPU available |
| **Coolify** | Not suitable | No per-second billing; always-on server cost regardless of usage |
| **Cloudron** | Not suitable | Not designed for ephemeral sandboxes |
| **Vercel** | Not suitable | No persistent compute; serverless functions have 10s–5min limits |

**Winner for bursty AI sandboxes**: Fly.io (cheapest, auto-stop, Sprites isolation). Daytona if you need gVisor-level isolation, GPU, or stateful snapshots between runs.

### Profile 3: Production SaaS (4 vCPU / 8 GB + DB + CDN)

A production SaaS with a backend (4 vCPU/8 GB), PostgreSQL database, and CDN for static assets.

| Platform | Monthly cost | Notes |
|----------|-------------|-------|
| **Fly.io** | ~$130–160 | performance-4x (~$124) + Fly Postgres (~$15–30 for small cluster) + bandwidth |
| **Daytona** | Not suitable | Not designed for production app hosting |
| **Coolify** | ~€20–40 | Hetzner AX41 (4 vCPU/64 GB) ~€35 + Coolify manages Postgres; best value |
| **Cloudron** | ~€20–40 + $15 sub | Same server + Cloudron subscription; adds SSO, app marketplace |
| **Vercel** | ~$20–50+ | Pro plan ($20) + external DB (Neon/PlanetScale ~$10–30) + bandwidth; no persistent compute |

**Winner for production SaaS**: Coolify on Hetzner (~€35/mo all-in) for maximum value. Fly.io (~$130–160/mo) for managed infrastructure with global distribution. Vercel for Next.js-heavy frontends with serverless backends.

---

## Decision Guide

### Use Fly.io when

- You need **global low-latency** — anycast routing puts compute near users automatically
- You want **managed infrastructure** without running your own servers
- Your workload benefits from **auto-stop/start** (bursty traffic, cost savings)
- You need **AI agent sandboxes** (Sprites) with per-second billing
- You're running **Elixir/Phoenix** or other distributed systems
- Budget: ~$2–130/mo depending on machine size

### Use Daytona when

- You need **AI agent code execution** with strong isolation (gVisor, stronger than Docker)
- You need **GPU sandboxes** (A100, H100, L40S) for ML workloads
- Your workload is **ephemeral** — create, run, destroy; per-second billing
- You need **stateful snapshots** — stop a sandbox and resume it later with full state
- You're building a **CI/CD pipeline** with ephemeral runners
- Budget: competitive for ephemeral; expensive for always-on

### Use Coolify when

- You want **full control** over your infrastructure and data
- You're **cost-sensitive** — Hetzner + Coolify is the cheapest option for always-on workloads
- You need **data sovereignty** — data never leaves your server
- You're comfortable managing a Linux server (updates, backups, monitoring)
- You want a **self-hosted Heroku/Render** experience
- Budget: ~€4–40/mo (server cost only)

### Use Cloudron when

- You need to host **off-the-shelf apps** (WordPress, Nextcloud, Gitea, etc.) with one-click installs
- You want **automatic updates, backups, and SSO** managed for you
- Your team is **non-technical** — Cloudron's UI is simpler than Coolify
- You need **LDAP/SSO** integration across all hosted apps
- You're packaging **custom apps** for a managed self-hosted environment
- Budget: ~€4–40/mo (server) + $15/mo (subscription for >2 apps)

### Use Vercel when

- You're building a **Next.js, React, or JAMstack** frontend
- You need **serverless functions** with global edge distribution
- Your backend is **stateless** — no persistent compute needed
- You want **zero-ops** deployment (git push → live)
- You need **preview deployments** per PR automatically
- Budget: Free (Hobby) to $20/mo (Pro) + external DB costs

---

## Workload-to-Platform Mapping

| Workload | Recommended | Alternative | Avoid |
|----------|-------------|-------------|-------|
| Always-on web app, global | Fly.io | Coolify (no global) | Daytona, Vercel |
| Always-on web app, single region | Coolify | Fly.io | Daytona, Vercel |
| AI agent code execution | Fly.io (Sprites) | Daytona (gVisor+GPU) | Coolify, Cloudron, Vercel |
| AI agent with GPU | Daytona | — | Fly.io (no GPU), others |
| Ephemeral CI/CD runners | Daytona | Fly.io (auto-stop) | Coolify, Cloudron, Vercel |
| Next.js / JAMstack frontend | Vercel | Fly.io | Coolify, Cloudron |
| Self-hosted apps (WordPress, etc.) | Cloudron | Coolify | Fly.io, Daytona, Vercel |
| Production SaaS, cost-sensitive | Coolify | Fly.io | Daytona |
| Production SaaS, global | Fly.io | Vercel (frontend) + Fly.io (backend) | Coolify (no global) |
| Dev environments / previews | Daytona | Vercel (frontend) | Coolify, Cloudron |
| Data sovereignty required | Coolify | Cloudron | Fly.io, Daytona, Vercel |

---

## Cold Start Latency

Cold starts matter for auto-stop workloads and serverless functions.

| Platform | Cold start | Notes |
|----------|-----------|-------|
| **Fly.io** (auto-stop) | ~200–500 ms | Firecracker VM boot; first request after idle period |
| **Daytona** | ~90 ms | Claimed by Daytona; gVisor sandbox resume |
| **Coolify** | None | Always-on containers; no cold start |
| **Cloudron** | None | Always-on containers; no cold start |
| **Vercel Edge Functions** | ~0–50 ms | V8 isolates; near-zero cold start |
| **Vercel Serverless Functions** | ~100–500 ms | Node.js runtime; varies by bundle size |

For latency-sensitive workloads: Vercel Edge Functions (fastest) → Daytona → Fly.io (auto-stop) → Fly.io (always-on, no cold start).

---

## AI / Agent Sandbox Suitability

| Feature | Fly.io (Sprites) | Daytona | Coolify | Cloudron | Vercel |
|---------|-----------------|---------|---------|----------|--------|
| Isolation model | Firecracker VM | gVisor (kernel) | Docker namespace | Docker namespace | V8 isolate |
| Isolation strength | High | Very high | Medium | Medium | Medium (JS only) |
| Per-second billing | Yes | Yes | No | No | Yes (invocations) |
| GPU support | No | Yes | No | No | No |
| Stateful snapshots | No | Yes | No | No | No |
| SDK/API for lifecycle | Yes (Machines API) | Yes (Python/TS SDK) | No | No | No |
| Max execution time | Unlimited | Unlimited | Unlimited | Unlimited | 5–15 min |
| Suitable for untrusted code | Yes | Yes (strongest) | No | No | Partial (Edge only) |

**For AI agent code execution**: Daytona is the strongest isolation (gVisor) with GPU support and stateful snapshots. Fly.io Sprites are a good alternative with lower cost for CPU-only workloads.

---

## Self-Hosted vs Managed Trade-offs

| Dimension | Self-hosted (Coolify/Cloudron) | Managed (Fly.io/Daytona/Vercel) |
|-----------|-------------------------------|--------------------------------|
| **Cost** | Server cost only (~€4–40/mo) | Higher per-unit cost |
| **Ops overhead** | You manage updates, backups, monitoring | Platform manages everything |
| **Data sovereignty** | Full control | Data on provider infrastructure |
| **Scaling** | Manual (resize server or add nodes) | Automatic (Fly.io, Vercel) |
| **Global distribution** | No (single server) | Yes (Fly.io, Vercel) |
| **Reliability** | Depends on your server/provider | SLA-backed |
| **Vendor lock-in** | Low (Docker-based, portable) | Medium–high |

**Rule of thumb**: Self-hosted (Coolify/Cloudron) wins on cost and control for single-region, always-on workloads. Managed (Fly.io/Vercel) wins on global distribution, auto-scaling, and zero-ops.

---

## Platform Docs

- **Fly.io**: `tools/deployment/fly-io.md` — flyctl CLI, Machines, Sprites, pricing
- **Daytona**: `tools/deployment/daytona.md` — SDK, sandbox lifecycle, GPU, snapshots
- **Coolify**: `tools/deployment/coolify.md` — setup, Docker management, server ops
- **Cloudron**: `tools/deployment/cloudron-app-packaging.md` — app packaging, manifest, addons
- **Vercel**: `tools/deployment/vercel.md` — CLI, deployments, environments, frameworks

---

## References

- Fly.io pricing: https://fly.io/docs/about/pricing/
- Fly.io calculator: https://fly.io/calculator
- Daytona pricing: https://www.daytona.io/pricing
- Coolify pricing: https://coolify.io/pricing
- Cloudron pricing: https://www.cloudron.io/pricing.html
- Vercel pricing: https://vercel.com/pricing
- Hetzner Cloud pricing: https://www.hetzner.com/cloud/
