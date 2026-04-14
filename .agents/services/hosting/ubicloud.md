---
description: Ubicloud — open-source IaaS on bare metal. Managed GitHub Actions runners (~10x cheaper), managed PostgreSQL, managed Kubernetes, VMs, networking, AI inference
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Ubicloud — Open Cloud on Bare Metal

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Open-source IaaS (AGPL v3). Managed SaaS *or* self-hosted control plane on your own bare metal.
- **Headline wins**: ~10x cheaper GitHub Actions runners (one-line migration), ~3x cheaper VMs / managed Postgres vs. AWS/Azure.
- **Source**: https://github.com/ubicloud/ubicloud (AGPL v3)
- **Docs**: https://www.ubicloud.com/docs/overview · API: https://www.ubicloud.com/docs/api-reference/overview
- **API base**: `https://api.ubicloud.com` (Beta). REST, JSON bodies, bearer token in `Authorization` header.
- **Console**: https://console.ubicloud.com
- **CLI**: `ubi` (Go, thin-client — every command round-trips to the server). `brew install ubicloud/cli/ubi` or download from https://github.com/ubicloud/cli/releases
- **Auth**: Personal access token per project. Env var `UBI_TOKEN`. Store in `~/.config/aidevops/credentials.sh` (600 perms) or `gopass`.
- **Token format**: `UBICLOUD_TOKEN_{PROJECT}` (e.g. `UBICLOUD_TOKEN_MAIN`).
- **Regions**: `eu-central-h1` (Hetzner/Falkenstein), `eu-north-h1` (Hetzner/Helsinki), `us-east-a2` (Leaseweb/Manassas). GitHub runners auto-provisioned across EU regions.
- **Free tier**: $1/month credit per account = 1,250 minutes of 2-vCPU runner time.
- **UBIDs**: Resource IDs carry a two-letter type prefix (`vm…`, `pj…`, `pg…`) — you can identify resource type from ID alone.
- **No MCP required** — `ubi` CLI + curl are sufficient. Zero context cost until invoked.

<!-- AI-CONTEXT-END -->

## Product surface

| Service | Use for | Pricing floor |
|---------|---------|---------------|
| **GitHub Actions runners** | CI at ~10x lower cost than GitHub-hosted; x64 + arm64 | $0.0008/min (2 vCPU) |
| **Elastic compute (VMs)** | Standard (dedicated CPU) or Burstable (shared CPU) Linux VMs | $6.65/mo (burstable-1), $26.60/mo (standard-2) |
| **Managed PostgreSQL** | Production Postgres with HA, read replicas, backups, extensions, pgvector, per-minute restore | $12.41/mo (hobby-1), $49/mo (standard-2) |
| **Managed Kubernetes** | Dedicated nodes, built-in LB, no hidden networking/egress fees | $45.60/mo (single-node + 1 worker) |
| **Load balancer** | Traffic distribution across VMs with health checks | Included |
| **Virtual networking** | Private subnets, firewalls, public IPv4 (fee) / IPv6 (free) | $3/mo public IPv4 |
| **Block storage** | Local NVMe, encryption at rest | Included in VM |
| **AI inference** | Managed inference endpoints + API keys for curated open models | Usage-based |
| **BYOC Postgres (AWS)** | Run Ubicloud-managed Postgres inside your own AWS account | Contact sales |

## Authentication

```bash
# Load token and set auth header (reuse $AUTH in all requests)
source ~/.config/aidevops/credentials.sh
export UBI_TOKEN="$UBICLOUD_TOKEN_MAIN"
AUTH="Authorization: Bearer $UBI_TOKEN"

# Verify access — list projects you can see
curl -s -H "$AUTH" https://api.ubicloud.com/project | jq -r '.items[] | "\(.id)  \(.name)"'
```

Getting a token: console.ubicloud.com → your project → **Tokens** → **Create Token** → copy.
Each Ubicloud project gets its own token, so multi-project setups store one env var per project:

```bash
export UBICLOUD_TOKEN_MAIN="..."
export UBICLOUD_TOKEN_CI="..."
export UBICLOUD_TOKEN_CLIENT_A="..."
```

## API design essentials

Full reference: https://www.ubicloud.com/docs/api-reference/overview

- **Global resources** (projects, firewalls, firewall rules) live outside any location. Access by ID only: `/project/{id}`.
- **Location-based resources** (VMs, PG databases, load balancers, private subnets, K8s clusters) live under `/project/{pid}/location/{loc}/{kind}/{name-or-id}`. Names are unique per project+location, so creating by name is idempotent (name = idempotency token).
- **Create**: `POST` to the resource's own URI (using its name), not the parent collection. For example `POST /project/{pid}/location/eu-north-h1/vm/my-vm` with a JSON body creates the VM if it does not exist.
- **List**: cursor-pagination via `order_column` + `start_after` + `page_size` (1–1000, default 1000). Response is `{ items: [...], count: N }`.
- **Status codes**: 200 success, 204 success no-content, 400 invalid, 401 not-authed, 403 forbidden, 404 not found, 409 bad state, 419 invalid token, 500 error.

## GitHub Actions runners (primary use case)

Ubicloud managed runners are typically the first Ubicloud service worth adopting: a **single workflow-label change** cuts CI cost ~10x with no other refactoring.

### Setup (one-time)

1. Create a Ubicloud account and add billing (card pre-auth of ~$5, refunded).
2. Install the **Ubicloud Managed Runners** GitHub App: console.ubicloud.com → **GitHub Runners** → **Connect New Account** → authorize on the repos or org.
3. Edit `.github/workflows/*.yml`: change `runs-on: ubuntu-latest` → `runs-on: ubicloud-standard-2` (or larger — see labels). Merge. Done.

### Runner labels

| Label | vCPU | Memory | Disk | $/min (standard / premium) |
|-------|------|--------|------|----------------------------|
| `ubicloud-standard-2` / `ubicloud` | 2 | 8 GB | 75 GB | 0.0008 / 0.0016 |
| `ubicloud-standard-4` | 4 | 16 GB | 150 GB | 0.0016 / 0.0032 |
| `ubicloud-standard-8` | 8 | 32 GB | 200 GB | 0.0032 / 0.0064 |
| `ubicloud-standard-16` | 16 | 64 GB | 300 GB | 0.0064 / 0.0128 |
| `ubicloud-standard-30` | 30 | 120 GB | 400 GB | 0.0120 / 0.0240 |
| `ubicloud-standard-2-arm` / `ubicloud-arm` | 2 (arm64) | 6 GB | 86 GB | 0.0008 |
| `ubicloud-standard-4-arm` | 4 (arm64) | 12 GB | 150 GB | 0.0016 |
| `ubicloud-standard-8-arm` | 8 (arm64) | 24 GB | 200 GB | 0.0032 |
| `ubicloud-standard-16-arm` | 16 (arm64) | 48 GB | 300 GB | 0.0064 |
| `ubicloud-standard-30-arm` | 30 (arm64) | 90 GB | 400 GB | 0.0120 |

Pattern: `ubicloud-standard-{vcpu}[-arm][-ubuntu-{2204|2404}]`. Default OS is Ubuntu 24.04 since 2025-11-23 (was 22.04). Pin explicitly with `-ubuntu-2204` if your workflow needs it.

### Workflow migration snippet

```yaml
# Before
jobs:
  test:
    runs-on: ubuntu-latest
    steps: [...]

# After — same vCPU/memory, 10x cheaper
jobs:
  test:
    runs-on: ubicloud-standard-2
    steps: [...]

# Or take advantage of the price gap to run bigger
jobs:
  test:
    runs-on: ubicloud-standard-8   # 4x the compute, still ~2.5x cheaper than ubuntu-latest
    steps: [...]
```

### Hardware, image parity, and caveats

- **x64 hardware**: standard runners = AMD EPYC 9454P (2 vCPU per physical core). Premium runners = AMD Ryzen 9 7950X3D, optimised for single-thread speed — ideal for big monorepos and test-heavy pipelines. Enable premium in the dashboard; jobs fall back to standard on capacity pressure.
- **arm64 hardware**: Ampere Altra Q80-30, one dedicated physical core per vCPU (better consistency than shared-SMT designs).
- **Image parity**: x64 images built from the official `actions/runner-images` HashiCorp packer templates, deployed a few days behind GitHub to avoid joining their rollback cycles. arm64 images are Ubicloud-built (GitHub does not publish an arm64 packer template); some packages may be missing versus GitHub's partner images — email `support@ubicloud.com` for additions.
- **GPU runners: deprecated** (end-of-life 2025-12-31). Migrate GPU-dependent jobs to standard runners + external GPU providers.
- **Ubicloud cache**: drop-in replacement for `actions/cache@v4` that stores to Ubicloud's blob store (faster, included in runner price). See https://ubicloud.com/docs/github-actions-integration/ubicloud-cache
- **Allowlisting**: private services behind a firewall need to allow Ubicloud's egress IPs from https://api.ubicloud.com/ips-v4 (dynamic list; re-fetch periodically).
- **SSH debug**: Ubicloud supports `ubicloud/upterm` or `mxschmitt/action-tmate` on its runners the same way GitHub-hosted does — see https://ubicloud.com/docs/github-actions-integration/debug-workflow-with-ssh

## Virtual machines

```bash
# List VMs across all locations
curl -s -H "$AUTH" https://api.ubicloud.com/project/{pid}/vm

# Create a VM idempotently by name (create or no-op)
curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"size":"standard-2","location":"eu-north-h1","boot_image":"ubuntu-noble","public_key":"ssh-ed25519 AAAA..."}' \
  https://api.ubicloud.com/project/{pid}/location/eu-north-h1/vm/my-vm

# Actions
curl -s -X POST -H "$AUTH" .../vm/{id}/restart
curl -s -X POST -H "$AUTH" .../vm/{id}/start
curl -s -X POST -H "$AUTH" .../vm/{id}/stop

# Delete
curl -s -X DELETE -H "$AUTH" https://api.ubicloud.com/project/{pid}/location/eu-north-h1/vm/my-vm
```

**Families:** `standard-N` (dedicated vCPU + 4 GB/vCPU) for general workloads. `burstable-N` (shared vCPU, bursts to 100% at micro-intervals, 2 GB/vCPU) for low-traffic sites, dev/test, and AI agents. Sizes: standard 2/4/8/16/30/60, burstable 1/2.

**Networking default:** each VM lives in an auto-created private subnet with free private IPv4/IPv6 and free public IPv6. Public IPv4 is opt-in at $3/mo. Egress quota: 0.625 TB/mo per 2 vCPUs; overage $3/TB. Ingress and same-region intra-resource traffic are free.

### `ubi` CLI

Faster than curl for interactive sessions. Thin client: every command goes to the server, so new features ship without CLI updates (but help output takes a round trip).

```bash
UBI_TOKEN="$UBICLOUD_TOKEN_MAIN" ubi vm list
ubi vm eu-north-h1/my-vm show
ubi vm eu-north-h1/my-vm ssh -- htop   # runs local `ssh`, whitelisted command
ubi vm eu-north-h1/my-vm scp :/etc/hostname ./remote-hostname
ubi pg eu-north-h1/main psql            # launches local `psql` against managed PG
ubi fw list
ubi kc list
ubi help -ru                            # recursive usage for every subcommand
```

Configure programs via env: `UBI_SSH`, `UBI_SFTP`, `UBI_SCP`, `UBI_PSQL`, `UBI_PG_DUMP`, `UBI_PG_DUMPALL`. Only these six commands can be executed from `ubi` — security boundary against rogue server responses.

## Managed PostgreSQL

Local NVMe, bare-metal-optimised data plane. ~3x cheaper than AWS RDS for comparable specs.

- **Families**: `hobby-{1,2}` (shared CPU, $12.41/$24.81 per month) and `standard-{2..60}` ($49 → $1498 per month).
- **HA**: synchronous replication with automatic failover on standard-family.
- **Read replicas**: same region or cross-region; promote via API.
- **Backups**: retained 7 days, per-minute restore granularity.
- **Extensions**: PG versions include pgvector, pg_stat_statements, postgis, and the usual suspects — full list at https://ubicloud.com/docs/managed-postgresql/extensions
- **Metrics destination**: point at an external Prometheus-compatible endpoint for scraping.
- **BYOC (AWS)**: run the managed experience inside your own AWS account for compliance / data residency. See https://ubicloud.com/docs/managed-postgresql/byoc

```bash
# Create
curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"size":"standard-2","version":"16","storage_size":64,"ha_type":"none"}' \
  https://api.ubicloud.com/project/{pid}/location/eu-north-h1/postgres/main
```

## Managed Kubernetes

- Dedicated nodes with local NVMe, control plane single-node (non-HA) or 3-node HA.
- No hidden networking / load balancer / egress fees — price is just the nodes.
- Built on standard upstream Kubernetes, not a fork; `kubectl` works normally.
- Integrates with Ubicloud load balancers and private subnets.

See https://ubicloud.com/docs/managed-kubernetes/overview

## AI inference

Managed inference endpoints for curated open models, with per-key access control.

- Create API keys with scoped permissions.
- Access standard OpenAI-compatible chat-completion endpoints.
- Playground UI in the console for prompt iteration.

See https://ubicloud.com/docs/inference/endpoint

## Hosted (managed SaaS) vs. self-managed (build your own cloud)

Same AGPL v3 codebase runs both the managed service and self-hosted versions on your own bare metal.

| Dimension | Managed SaaS (console.ubicloud.com) | Self-managed (build your own cloud) |
|-----------|-------------------------------------|--------------------------------------|
| Time to first VM | Minutes (card + console) | Hours to days (lease bare metal, clone repo, cloudify each host) |
| Operational burden | Zero | Full — OS patching, control plane upgrades, incident response, capacity planning |
| Bare metal contract | Managed by Ubicloud | You contract directly with Hetzner / Leaseweb / Latitude.sh |
| Cost model | Per-minute usage, billed by Ubicloud | Flat monthly bare-metal lease + Ubicloud is free; break-even above ~60% utilisation |
| Data residency | Ubicloud regions (DE, FI, US-VA) | Anywhere the provider ships |
| Compliance control | Ubicloud's posture (good enough for most; see trust center) | You own the boundary — required for some regulated workloads |
| Multi-tenant isolation | Ubicloud's ABAC across projects | You decide |
| Software updates | Automatic | Manual — `git pull` + re-run cloudify scripts |
| Best for | CI runners, product apps, managed Postgres, dev/test, startups | Long-lived heavy workloads, compliance-driven estates, teams with existing Hetzner spend, AGPL-acceptable consumers |
| Escape hatch | Can export data and migrate to self-managed (same codebase) | Can migrate to managed — zero lock-in either way |

### Decision rule of thumb

1. **CI runners only?** → Managed SaaS. The one-line workflow change is worth more than the monthly minimum.
2. **Spiky compute, no bare metal team?** → Managed SaaS. Pay per minute, no lease commitments.
3. **Steady high utilisation + already leasing Hetzner?** → Model both. Self-managed can be cheaper above ~60% host utilisation if ops time is free.
4. **AGPL v3 is a blocker for your product?** → Managed SaaS only. You consume the service; you don't distribute the control plane so AGPL does not reach your code.
5. **Strict data-residency, custom network topology, or bring-your-own-hardware?** → Self-managed, or BYOC Postgres on AWS.

### Self-managed quickstart

```bash
# On your workstation
git clone git@github.com:ubicloud/ubicloud.git
cd ubicloud
./demo/generate_env                                    # secrets for the demo
docker-compose -f demo/docker-compose.yml up           # db-migrator + app + postgres

# Create first user at http://localhost:3000
# Lease bare metal at https://www.hetzner.com/sb and populate .env:
#   HETZNER_USER, HETZNER_PASSWORD, HETZNER_SSH_PUBLIC_KEY, HETZNER_SSH_PRIVATE_KEY

# Cloudify each leased host (registers it as data-plane capacity)
docker exec -it ubicloud-app ./demo/cloudify_server

# Create VMs via the console — same UX as the managed service
```

Note: the cloudify script currently targets Hetzner leases only. Additional providers (Leaseweb, Latitude.sh) are supported for the managed service; Hetzner is the only automated path for self-managed as of early 2026.

## Related agents

| Resource | Path | Why cross-reference it |
|----------|------|------------------------|
| GitHub Actions CI/CD | `tools/git/github-actions.md` | The primary integration point — the Managed Runner Alternatives section lists Ubicloud labels and the migration snippet |
| Hetzner Cloud | `services/hosting/hetzner.md` | Ubicloud's managed SaaS runs on Hetzner bare metal for all EU regions; self-managed starts with a Hetzner lease |
| Cloudflare platform | `services/hosting/cloudflare.md` + `cloudflare-platform-skill/` | Alternative edge/compute platform — use Cloudflare for Workers/edge, Ubicloud for long-running VMs and managed Postgres |
| Cloudron | `services/hosting/cloudron.md` | Self-hosted PaaS you can run *on top of* a Ubicloud VM when you want Cloudron's app catalog on Ubicloud compute |
| Proxmox | `services/hosting/proxmox-full-skill.md` | Alternative self-managed virtualisation layer — Proxmox for on-prem bare metal you already own, Ubicloud for cloud-UX on leased bare metal |
| Localhost / local-hosting | `services/hosting/local-hosting.md`, `services/hosting/localhost.md` | Dev-loop alternative before committing to a runner provider |
| Vercel deployment | `tools/deployment/vercel.md` | Alternative for frontend/serverless — use Vercel for Next.js edge, Ubicloud for the backend / Postgres |
| Agent routing | `reference/agent-routing.md` | How to dispatch Ubicloud infrastructure work — typically `Build+` (code / CI) or a `services/hosting/*` context load |
| Build agent (meta) | `tools/build-agent/build-agent.md` + `scripts/commands/build-agent.md` | How this agent was created; use the same command to author peer hosting agents |

## When to enable an MCP instead

Ubicloud has no official MCP server as of early 2026. For frequent interactive use, the `ubi` CLI binary is the closest equivalent — a single static Go binary, no runtime dependencies, per-command server round-trips. If a community MCP appears, update the `Quick Reference` block, add the MCP glob pattern to this agent's frontmatter (`tools: { ubicloud-mcp_*: true }`), and register it in `mcp-registry.mjs` + `agent-loader.mjs` per `tools/build-agent/build-agent.md`.

## Troubleshooting

- **401 / 419 on API calls**: token expired or revoked. Regenerate in console → Tokens. Token is per-project; don't reuse across projects.
- **Runner job stuck in queue**: check Ubicloud status page; capacity shortfalls in a single region auto-route to the other EU region, but premium-only jobs without fallback can wait.
- **arm64 package missing**: install it manually in the workflow, or email `support@ubicloud.com` with the package name.
- **`ubi` help is slow**: thin-client design, every command round-trips. Cache `ubi help -ru` output if you need offline reference.
- **Self-managed cloudify fails**: verify Hetzner credentials in `.env`, confirm the leased box is reachable over SSH, check `docker logs ubicloud-app` for the cloudify script output.
- **Data residency mismatch**: managed service regions are fixed (Germany, Finland, Virginia). For other regions, go self-managed and lease bare metal where you need it — or use BYOC Postgres on AWS.
