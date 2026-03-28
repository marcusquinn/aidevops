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
| **Fly.io** | Managed PaaS (Firecracker VMs) | Global apps, AI sandboxes, auto-stop/start | Per-second compute + storage |
| **Daytona** | Cloud sandbox (SaaS) | AI agent code execution, GPU, ephemeral CI | Per-second, per-resource |
| **Coolify** | Self-hosted PaaS | Cost control, data sovereignty, Docker apps | Server cost only |
| **Cloudron** | Self-hosted app platform | Off-the-shelf apps, SSO, non-technical teams | Server cost + optional subscription |
| **Vercel** | Serverless/Edge PaaS | Next.js, JAMstack, serverless functions | Invocations + bandwidth |

**Platform docs**: `fly-io.md` | `daytona.md` | `coolify.md` | `cloudron-app-packaging.md` | `vercel.md`

<!-- AI-CONTEXT-END -->

Pricing figures are approximate — verify before committing: [Fly.io](https://fly.io/docs/about/pricing/) · [Daytona](https://www.daytona.io/pricing) · [Coolify](https://coolify.io/pricing) · [Cloudron](https://www.cloudron.io/pricing.html) · [Vercel](https://vercel.com/pricing) · [Hetzner](https://www.hetzner.com/cloud/)

---

## Feature Comparison Matrix

| Dimension | Fly.io | Daytona | Coolify | Cloudron | Vercel |
|-----------|--------|---------|---------|----------|--------|
| **Deployment type** | Managed PaaS | Cloud sandbox | Self-hosted PaaS | Self-hosted app platform | Serverless/Edge PaaS |
| **Compute model** | Firecracker micro-VMs | gVisor sandboxes | Docker containers | Docker containers | Serverless functions |
| **Always-on support** | Yes | Yes (stop/start) | Yes | Yes | No |
| **Auto-stop/start** | Yes (built-in) | Yes (manual stop) | No | No | N/A |
| **Cold start latency** | ~200–500 ms | ~90 ms | None | None | ~0–500 ms (Edge/Serverless) |
| **Global distribution** | Yes (30+ regions, anycast) | No | No (your server) | No (your server) | Yes (100+ PoPs) |
| **Persistent volumes** | Yes (NVMe, region-specific) | Yes (snapshots) | Yes (Docker volumes) | Yes (/app/data) | No (external only) |
| **Managed databases** | Fly Postgres, Upstash Redis | No | PostgreSQL, MySQL, MongoDB, Redis | MySQL, PostgreSQL, Redis | No (external only) |
| **AI agent sandboxes** | Yes (Sprites) | Yes (core use case) | No | No | No |
| **AI isolation model** | Firecracker VM (high) | gVisor kernel (very high) | Docker namespace (medium) | Docker namespace (medium) | V8 isolate (JS only) |
| **GPU support** | No | Yes (A100, H100, L40S) | No | No | No |
| **Stateful snapshots** | No | Yes | No | No | No |
| **SDK/API lifecycle** | Yes (Machines API) | Yes (Python/TS SDK) | No | No | No |
| **Max execution time** | Unlimited | Unlimited | Unlimited | Unlimited | 5–15 min |
| **Self-hosted option** | No | No | Yes | Yes | No |
| **Data sovereignty** | No | No | Yes | Yes | No |
| **App marketplace** | No | No | No | Yes (200+ apps) | No |
| **SSO/LDAP** | No | No | No | Yes (built-in) | No |
| **Automatic SSL** | Yes | N/A | Yes (Let's Encrypt) | Yes (Let's Encrypt) | Yes |
| **Billing model** | Per-second compute + storage | Per-second, per-resource | Server cost only | Server cost + optional sub | Invocations + bandwidth |
| **Free tier** | Yes (3 VMs) | Yes (credits) | Yes (software free) | Yes (2 apps) | Yes (generous) |

---

## Pricing Analysis

### Fly.io (shared CPU, approximate)

| Machine | vCPU | RAM | Always-on/mo | Per-hour |
|---------|------|-----|-------------|---------|
| shared-cpu-1x | 1 shared | 256 MB | ~$1.94 | ~$0.0027 |
| shared-cpu-2x | 2 shared | 512 MB | ~$3.88 | ~$0.0054 |
| shared-cpu-4x | 4 shared | 1 GB | ~$7.76 | ~$0.0108 |
| performance-1x | 1 dedicated | 2 GB | ~$31.00 | ~$0.0430 |
| performance-2x | 2 dedicated | 4 GB | ~$62.00 | ~$0.0860 |
| performance-4x | 4 dedicated | 8 GB | ~$124.00 | ~$0.1720 |

Storage: ~$0.15/GB/month. Bandwidth: ~$0.02/GB after 160 GB free.

### Daytona (per-second, per-resource)

Billed per-second for active vCPU + RAM + disk; stopped sandboxes pay disk only. For reference (March 2026): ~$48–50/month for always-on 1 vCPU/1 GB vs Fly.io's ~$5.92/month — significantly more expensive for always-on, competitive for bursty/ephemeral use. Check https://www.daytona.io/pricing for current rates.

### Coolify (self-hosted — server cost only)

| Provider | Spec | Monthly |
|----------|------|---------|
| Hetzner CX22 | 2 vCPU, 4 GB RAM | ~€4.35 |
| Hetzner CX32 | 4 vCPU, 8 GB RAM | ~€8.70 |
| DigitalOcean Basic | 2 vCPU, 4 GB RAM | ~$24 |
| Vultr | 2 vCPU, 4 GB RAM | ~$24 |

Coolify software is free (AGPL). Coolify Cloud (managed): check https://coolify.io/pricing.

### Cloudron (self-hosted — server cost + optional subscription)

Same server costs as Coolify. Subscription: free for ≤2 apps; ~$15/month for unlimited apps + priority support.

### Vercel (invocation-based)

| Plan | Monthly | Bandwidth | Function invocations |
|------|---------|-----------|---------------------|
| Hobby | Free | 100 GB | 100K/day |
| Pro | $20/user | 1 TB | 1M/day |
| Enterprise | Custom | Custom | Custom |

Edge Functions: ~$0.60/million invocations. Serverless Functions: ~$0.18/GB-hour compute.

---

## Worked Cost Examples

### Profile 1: Always-On Web App (1 vCPU / 1 GB RAM, 24/7)

| Platform | Monthly cost | Notes |
|----------|-------------|-------|
| **Fly.io** | ~$5.92 | shared-cpu-4x + min_machines_running=1 |
| **Daytona** | ~$48–50 | Per-second billing; expensive for always-on |
| **Coolify** | ~€4–8 | Hetzner CX22/CX32; best value for always-on |
| **Cloudron** | ~€4–8 + $15 sub | Same server + subscription for >2 apps |
| **Vercel** | Not suitable | Serverless only |

**Winner**: Coolify on Hetzner (~€4–8/mo) for self-managed. Fly.io (~$5.92/mo) for managed with no ops overhead.

### Profile 2: Bursty AI Agent Sandbox (~4 hours/day active)

| Platform | Monthly cost | Notes |
|----------|-------------|-------|
| **Fly.io** | ~$0.65–1.30 | Auto-stop; ~120h × $0.0108/hr; Sprites isolation |
| **Daytona** | ~$6–8 | Per-second; gVisor isolation; GPU available |
| **Coolify** | Not suitable | No per-second billing |
| **Cloudron** | Not suitable | Not designed for ephemeral sandboxes |
| **Vercel** | Not suitable | 5–15 min function limits |

**Winner**: Fly.io (cheapest, auto-stop, Sprites). Daytona if gVisor isolation, GPU, or stateful snapshots needed.

### Profile 3: Production SaaS (4 vCPU / 8 GB + DB + CDN)

| Platform | Monthly cost | Notes |
|----------|-------------|-------|
| **Fly.io** | ~$130–160 | performance-4x (~$124) + Fly Postgres (~$15–30) + bandwidth |
| **Daytona** | Not suitable | Not designed for production app hosting |
| **Coolify** | ~€20–40 | Hetzner AX41 (~€35); Coolify manages Postgres |
| **Cloudron** | ~€20–40 + $15 sub | Same server + subscription; adds SSO, app marketplace |
| **Vercel** | ~$20–50+ | Pro ($20) + external DB (~$10–30); no persistent compute |

**Winner**: Coolify on Hetzner (~€35/mo all-in). Fly.io (~$130–160/mo) for managed + global distribution.

---

## Decision Guide

### Use Fly.io when
- **Global low-latency** — anycast routing puts compute near users automatically
- **Managed infrastructure** without running your own servers
- **Auto-stop/start** for bursty traffic and cost savings
- **AI agent sandboxes** (Sprites) with per-second billing
- Budget: ~$2–130/mo

### Use Daytona when
- **AI agent code execution** with strong isolation (gVisor, stronger than Docker)
- **GPU sandboxes** (A100, H100, L40S) for ML workloads
- **Ephemeral workloads** — create, run, destroy; per-second billing
- **Stateful snapshots** — stop and resume with full state
- Budget: competitive for ephemeral; expensive for always-on

### Use Coolify when
- **Full control** over infrastructure and data
- **Cost-sensitive** — Hetzner + Coolify is cheapest for always-on
- **Data sovereignty** — data never leaves your server
- Comfortable managing a Linux server
- Budget: ~€4–40/mo (server cost only)

### Use Cloudron when
- **Off-the-shelf apps** (WordPress, Nextcloud, Gitea) with one-click installs
- **Automatic updates, backups, and SSO** managed for you
- **Non-technical teams** — simpler UI than Coolify
- **LDAP/SSO** integration across all hosted apps
- Budget: ~€4–40/mo (server) + $15/mo (subscription for >2 apps)

### Use Vercel when
- **Next.js, React, or JAMstack** frontend
- **Serverless functions** with global edge distribution
- **Stateless backend** — no persistent compute needed
- **Preview deployments** per PR automatically
- Budget: Free (Hobby) to $20/mo (Pro) + external DB

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

**Self-hosted vs managed rule of thumb**: Coolify/Cloudron wins on cost and control for single-region, always-on workloads. Fly.io/Vercel wins on global distribution, auto-scaling, and zero-ops.

---

## AI Model Inference Hosting

For AI model inference, fine-tuning, and custom model hosting, see the dedicated infrastructure agents. Managed platforms (Fireworks, Together AI, Cloudflare Workers AI, NEAR AI Cloud) expose OpenAI-compatible APIs -- change `base_url` only. Cloud GPU (raw providers) depends on the inference server you deploy: vLLM and TGI expose OpenAI-compatible APIs; other stacks may not -- verify your runtime's API compatibility and auth behaviour before integrating.

### Platform Comparison

| Platform | Type | Models | Fine-tuning | Custom uploads | Dedicated GPUs | CLI | Docs |
|----------|------|--------|-------------|----------------|----------------|-----|------|
| **Fireworks AI** | Managed inference + training | 100+ open-source | SFT, DPO, RFT, Training SDK | Yes (HF, S3, Azure) | A100/H100/H200/B200 | `firectl` | `tools/infrastructure/fireworks.md` |
| **Together AI** | Managed inference + training | 100+ open-source | SFT, DPO, RL | Yes | H100/H200/B200/GB200 | REST API | `tools/infrastructure/together.md` |
| **Cloudflare Workers AI** | Edge serverless inference | ~30 open-source | No | No (custom via form) | No (serverless GPUs) | `wrangler` | `tools/infrastructure/cloudflare-ai.md` |
| **NVIDIA Cloud** | Cloud API + self-host runtime | 100+ (build.nvidia.com) | NeMo (separate) | Self-host any NIM container | Self-host or DGX Cloud | REST API | `tools/infrastructure/nvidia-cloud.md` |
| **NEAR AI Cloud** | TEE-backed private inference | ~10 (open + closed proxy) | No | No | No | REST API only | `tools/infrastructure/nearai.md` |
| **Cloud GPU** | Raw GPU providers | Any (self-managed) | Any (self-managed) | N/A | RunPod/Vast.ai/Lambda | Provider CLIs | `tools/infrastructure/cloud-gpu.md` |

### Pricing Comparison (common models, $/M tokens, March 2026)

| Model | Fireworks | Together AI | Cloudflare | NEAR AI | Notes |
|-------|-----------|-------------|------------|---------|-------|
| GPT-OSS 120B (in/out) | $0.15 / $0.60 | $0.15 / $0.60 | $0.35 / $0.75 | $0.15 / $0.55 | CF ~2x more expensive |
| DeepSeek V3 (in/out) | $0.56 / $1.68 | $0.60 / $1.70 | N/A | $1.05 / $3.10 | NEAR ~2x (TEE premium) |
| Llama 3.3 70B (in/out) | $0.90 / $0.90 | $0.88 / $0.88 | $0.29 / $2.25 | N/A | CF cheap input, expensive output |
| Qwen3 30B A3B (in/out) | $0.15 / $0.60 | $0.15 / $1.50 | $0.05 / $0.34 | $0.15 / $0.55 | CF cheapest for this model |
| GLM-5 (in/out) | $1.00 / $3.20 | $1.00 / $3.20 | N/A | $0.85 / $3.30 | Parity across platforms |
| Kimi K2.5 (in/out) | $0.60 / $3.00 | $0.50 / $2.80 | $0.60 / $3.00 | N/A | Together slightly cheaper |
| Batch discount | 50% off | 50% off | N/A | N/A | Fireworks and Together both offer batch |

NVIDIA Cloud (build.nvidia.com): Free cloud endpoints for prototyping (1000 API credits). Production via self-hosted NIM containers (free with NVIDIA AI Enterprise license or DGX). No published per-token serverless pricing — the cloud API is for prototyping, production runs on your own GPUs via NIM.

### Decision Guide

| Requirement | Recommended | Alternative |
|-------------|-------------|-------------|
| Production inference, lowest cost | Fireworks or Together AI | Cloudflare (small models) |
| Fine-tuning (SFT/DPO/RFT) | Fireworks | Together AI |
| Custom model training loops | Fireworks (Training SDK) | Cloud GPU (full control) |
| Edge/global inference, Cloudflare stack | Cloudflare Workers AI | Fireworks (multi-region) |
| Privacy-critical (TEE, regulated data) | NEAR AI Cloud | Self-hosted NIM in TEE |
| Self-hosted optimized inference | NVIDIA Cloud (NIM) | vLLM/TGI on Cloud GPU |
| Anonymized closed-model access | NEAR AI Cloud | Direct provider APIs |
| Batch processing at scale | Fireworks or Together AI (50% off) | Cloud GPU |
| GPU clusters for training | Together AI (GPU Clusters) | Cloud GPU providers |
| Cheapest experimentation | Cloudflare (10K free neurons/day) | NVIDIA Cloud (free credits) |

## Related

- `tools/deployment/fly-io.md` — Fly.io deployment agent (flyctl, Machines API, Sprites, Tigris)
- `tools/deployment/daytona.md` — Daytona sandbox agent (gVisor, GPU, ephemeral CI)
- `tools/deployment/coolify.md` — Coolify self-hosted PaaS agent
- `tools/deployment/vercel.md` — Vercel serverless/edge agent
- `tools/deployment/uncloud.md` — Uncloud multi-machine container orchestration
- `.agents/scripts/fly-io-helper.sh` — Fly.io CLI helper (deploy, scale, secrets, volumes, logs, ssh, postgres)
