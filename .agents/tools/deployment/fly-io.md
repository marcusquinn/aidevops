---
description: Fly.io deployment — flyctl CLI, Fly Machines, global anycast, pricing
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Fly.io Deployment Agent

## Quick Reference

- **CLI**: `flyctl` (alias: `fly`) — `curl -L https://fly.io/install.sh | sh` or `brew install flyctl`
- **Auth**: `fly auth login` → `fly auth whoami`
- **Helper**: `.agents/scripts/fly-io-helper.sh <cmd> <app> [args]` — `deploy`, `scale <N>`, `status`, `secrets`, `volumes`, `logs`, `machines list`, `ssh`, `postgres <db> status`, `apps`
- **Config**: `fly.toml` (per-app, repo root) | [Dashboard](https://fly.io/dashboard) | [Docs](https://fly.io/docs/) | [Pricing](https://fly.io/docs/about/pricing/)
- **Concepts**: Fly Machines (Firecracker micro-VMs), anycast routing, auto-stop/start, Sprites (AI sandboxes), Tigris (S3-compatible storage)
- **Best for**: low-latency global apps, AI sandboxes, Elixir/Phoenix, multi-region DBs (LiteFS/Fly Postgres), GPU inference
- **Not for**: serverless functions (CF Workers), static-only sites (CF Pages), Kubernetes-native, Windows containers

## fly.toml

```toml
app = "my-app-name"
primary_region = "lhr"
[build]
  dockerfile = "Dockerfile"
[env]
  PORT = "8080"
[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = "stop"  # "stop"|"suspend"|true|false
  auto_start_machines = true
  min_machines_running = 0     # 0=auto-stop; 1+=always-on
  [http_service.concurrency]
    type = "requests"
    hard_limit = 250
[[vm]]
  memory = "256mb"             # 256mb–64gb
  cpu_kind = "shared"          # "shared"|"performance"
  cpus = 1
[[mounts]]
  source = "myapp_data"
  destination = "/data"
# [[http_service.checks]] — grace_period, interval, method, path, timeout
```

GPU: `vm.size = "a100-40gb"` | `a100-80gb` | `l40s`. Optional: `swap_size_mb = 32768`.

## Deploy and Manage

```bash
fly launch --name my-app --region lhr          # New app (creates fly.toml)
fly deploy [--strategy rolling|canary]         # Deploy current
fly releases --app my-app                      # Rollback: redeploy previous image
fly machines list|start|stop|destroy <id> --app my-app [--force]
fly ssh console --app my-app [--command "rails db:migrate"]
fly status --app my-app                        # Overview + health
fly logs --app my-app                          # Stream logs
fly config validate --app my-app               # Validate fly.toml
# Machines REST API — base: https://api.machines.dev, token: fly tokens create
curl "${FLY_API_HOSTNAME}/v1/apps/{app}/machines[/{id}[/{action}]]" \
  -H "Authorization: Bearer ${FLY_API_TOKEN}" [-d '{"signal":"SIGTERM","timeout":"30s"}']
```

## Pricing

| Tier | CPU | RAM | ~$/mo |
|------|-----|-----|-------|
| `shared-cpu-1x` | 1 shared | 256 MB | $1.94 |
| `shared-cpu-4x` | 4 shared | 1 GB | $7.76 |
| `performance-2x` | 2 dedicated | 4 GB | $62 |
| `performance-8x` | 8 dedicated | 16 GB | $248 |

**GPU**: `a100-40gb` (~$2.50/h), `a100-80gb` (~$3.50/h), `l40s` (~$2.00/h) — `fly platform vm-sizes` for full list; auto-stop to avoid idle costs.
**Storage**: Volumes ~$0.15/GB/mo, snapshots ~$0.03/GB/mo, Tigris ~$0.02/GB/mo (free egress to Fly), outbound ~$0.02/GB (160 GB free).
**Free tier** (Hobby): 3 shared-cpu-1x 256 MB, 3 GB volumes, 160 GB transfer, shared IPv4 (dedicated: $2/mo).

## Scaling, Secrets, Volumes

```bash
fly scale count 3 --app my-app                    # Horizontal (per-region: --region lhr)
fly scale vm performance-2x --app my-app          # Vertical
fly scale memory 1024 --app my-app
# Secrets — encrypted at rest, injected as env vars, never in logs
echo "value" | fly secrets set MY_SECRET=- --app my-app  # stdin — never as argument
fly secrets import --app my-app < .env.production
fly secrets list --app my-app                             # Names only
# Volumes — NVMe SSDs, region-locked
fly volumes create myapp_data --size 10 --region lhr --app my-app
fly volumes extend <vol-id> --size 20 --app my-app   # Increase only
fly volumes destroy <vol-id> --app my-app             # IRREVERSIBLE
```

## Storage and Databases

**Tigris** (S3-compatible): `fly storage create` auto-sets `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT_URL_S3`, `AWS_REGION`, `BUCKET_NAME`.

```bash
fly storage create | list | dashboard
fly postgres create --name my-db --region lhr  # Managed (you handle upgrades)
fly postgres attach my-db --app my-app         # Sets DATABASE_URL
fly redis create --name my-redis --region lhr  # Upstash (serverless, pay per request)
fly redis attach my-redis --app my-app         # Sets REDIS_URL
```

## Networking and Multi-Region

- **Private mesh (6PN)**: WireGuard across all org apps — `<app>.internal` (IPv6)
- **Flycast** (private LB): `fly ips allocate-v6 --private` → `<app>.flycast` (not internet-exposed)
- `fly regions add|remove|list iad --app my-app`
- Fly Postgres auto-routes read replicas; set `PRIMARY_REGION` for writes
- Production: 2+ Machines, `min_machines_running = 1`

## Sprites (AI Agent Sandboxes)

TypeScript SDK: `@fly/sprites` ([Sprites SDK](https://github.com/superfly/sprites-js)).

```bash
fly machines run my-image --app my-sprites-app --region lhr \
  --vm-size shared-cpu-1x --env AGENT_ID=agent-123 --restart no
```

## Related

- `tools/deployment/hosting-comparison.md` — Fly.io vs alternatives
- `.agents/scripts/fly-io-helper.sh` — helper script source
- [Docs](https://fly.io/docs/) | [Regions](https://fly.io/docs/reference/regions/) | [Machines API](https://fly.io/docs/machines/api/) | [Tigris](https://fly.io/docs/tigris/) | [LiteFS](https://fly.io/docs/litefs/) | [Blueprints](https://fly.io/docs/blueprints/) | [Community](https://community.fly.io/)
