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

# Fly.io Deployment Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **CLI**: `flyctl` (alias: `fly`) — install: `curl -L https://fly.io/install.sh | sh` or `brew install flyctl`
- **Auth**: `fly auth login` → `fly auth whoami`
- **Script**: `.agents/scripts/fly-io-helper.sh`
- **Config**: `fly.toml` (per-app, in repo root)
- **Dashboard**: `https://fly.io/dashboard`
- **Docs**: `https://fly.io/docs/` | **Pricing**: `https://fly.io/docs/about/pricing/` | **Calculator**: `https://fly.io/calculator`

**Commands**: `deploy|scale|status|secrets|volumes|logs|apps|machines|postgres|redis|ssh`

**Usage**: `./.agents/scripts/fly-io-helper.sh [command] [app] [args]`

**Key concepts**: Fly Machines (Firecracker micro-VMs), anycast routing, auto-stop/start, Sprites (AI sandboxes)

<!-- AI-CONTEXT-END -->

Fly.io runs apps on Firecracker micro-VMs (Fly Machines) across 30+ regions with anycast routing. Best for latency-sensitive workloads, AI agent sandboxes (Sprites), and global apps needing auto-stop cost savings.

**Best use cases**: global low-latency apps, AI agent sandboxes, Elixir/Phoenix, full-stack apps, cost-sensitive workloads, multi-region databases (LiteFS/Fly Postgres).

**When NOT to use**: serverless functions (use Cloudflare Workers/Vercel Edge), static sites only (use Cloudflare Pages/Vercel), Kubernetes-native workloads, Windows containers.

## fly.toml Configuration

```toml
app = "my-app-name"
primary_region = "lhr"

[build]
  dockerfile = "Dockerfile"

[env]
  PORT = "8080"
  NODE_ENV = "production"

[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = true   # Stop when idle (cost saving)
  auto_start_machines = true  # Start on first request
  min_machines_running = 0    # 0 = full auto-stop; 1 = always-on

  [http_service.concurrency]
    type = "requests"
    hard_limit = 250
    soft_limit = 200

[[vm]]
  memory = "256mb"
  cpu_kind = "shared"  # or "performance" for dedicated
  cpus = 1

[[mounts]]
  source = "myapp_data"
  destination = "/data"

[[http_service.checks]]
  grace_period = "10s"
  interval = "30s"
  method = "GET"
  path = "/health"
  timeout = "5s"
```

| Option | Values | Notes |
|--------|--------|-------|
| `primary_region` | `lhr`, `iad`, `nrt`, etc. | Where volumes and primary Machine live |
| `auto_stop_machines` | `true`/`false` | Stop idle Machines (saves cost) |
| `min_machines_running` | `0`–N | 0 = full auto-stop, 1+ = always-on |
| `cpu_kind` | `shared`, `performance` | Shared = burstable, Performance = dedicated |
| `memory` | `256mb`–`64gb` | RAM per Machine |

## Deployment

```bash
# Launch new app (creates fly.toml)
fly launch --name my-app --region lhr

# Deploy
fly deploy

# Deploy with specific image or build args
fly deploy --image registry.fly.io/my-app:latest
fly deploy --build-arg NODE_VERSION=20

# Rolling or canary deploy strategy
fly deploy --strategy rolling --app my-app
fly deploy --strategy canary --app my-app

# Rollback: list releases then redeploy previous image
fly releases --app my-app
fly deploy --image <previous-image-ref>

# Status and logs
fly status --app my-app
fly logs --app my-app
fly open --app my-app
```

## Fly Machines

Firecracker micro-VMs — sub-second start, billed per second of active time.

```bash
fly machines list --app my-app
fly machines start <machine-id> --app my-app
fly machines stop <machine-id> --app my-app
fly machines destroy <machine-id> --app my-app --force
fly ssh console --app my-app
fly ssh console --app my-app --command "rails db:migrate"
```

| Size | CPU | RAM | Use case |
|------|-----|-----|----------|
| `shared-cpu-1x` | 1 shared | 256 MB | Dev, low-traffic |
| `shared-cpu-2x` | 2 shared | 512 MB | Light production |
| `shared-cpu-4x` | 4 shared | 1 GB | Medium workloads |
| `performance-1x` | 1 dedicated | 2 GB | CPU-intensive |
| `performance-2x` | 2 dedicated | 4 GB | High-throughput |
| `performance-4x` | 4 dedicated | 8 GB | Heavy compute |
| `performance-8x` | 8 dedicated | 16 GB | AI inference |

## Scaling

```bash
fly scale count 3 --app my-app                    # Horizontal
fly scale count 2 --region lhr --app my-app       # Per-region
fly scale vm performance-2x --app my-app          # Vertical
fly scale memory 1024 --app my-app
fly scale show --app my-app
```

## Secrets Management

Secrets are injected as env vars, encrypted at rest, never appear in logs.

```bash
# Set (use stdin — never pass value as argument)
echo "my-secret-value" | fly secrets set MY_SECRET=- --app my-app
fly secrets import --app my-app < .env.production

# List names (values never shown)
fly secrets list --app my-app
fly secrets unset MY_SECRET --app my-app
```

## Volumes (Persistent Storage)

NVMe SSDs, region-specific — a volume in `lhr` can only attach to a Machine in `lhr`.

```bash
fly volumes create myapp_data --size 10 --region lhr --app my-app
fly volumes list --app my-app
fly volumes extend <volume-id> --size 20 --app my-app  # Increase only — cannot shrink
fly volumes destroy <volume-id> --app my-app           # IRREVERSIBLE
```

Create volumes before deploying apps that need them. For multi-region shared data, use Fly Postgres or LiteFS instead.

## Databases

### Fly Postgres

Managed PostgreSQL on Fly Machines — you manage upgrades.

```bash
fly postgres create --name my-app-db --region lhr
fly postgres attach my-app-db --app my-app  # Sets DATABASE_URL secret
fly postgres connect --app my-app-db
fly status --app my-app-db
```

### Upstash Redis

Serverless Redis — pay per request, no idle cost.

```bash
fly redis create --name my-app-redis --region lhr
fly redis attach my-app-redis --app my-app  # Sets REDIS_URL secret
fly redis list
```

## Multi-Region

```bash
fly regions add iad --app my-app
fly regions remove iad --app my-app
fly regions list --app my-app
fly regions backup iad --app my-app  # Failover region
```

Fly Postgres handles read replica routing automatically when `DATABASE_URL` points to the cluster. Set `PRIMARY_REGION` env var to direct writes to the primary.

## Sprites (AI Agent Sandboxes)

Isolated ephemeral Machines for running untrusted AI agent code.

```bash
fly machines run my-sandbox-image \
  --app my-sprites-app \
  --region lhr \
  --vm-size shared-cpu-1x \
  --env AGENT_ID=agent-123 \
  --restart no

fly machines destroy <machine-id> --app my-sprites-app --force
```

## Logs and Monitoring

```bash
fly logs --app my-app
fly logs --app my-app --region lhr
fly status --app my-app
fly dashboard --app my-app  # Opens browser dashboard
```

## Pricing

Bills per second of Machine active time + storage + bandwidth. Auto-stop eliminates idle costs.

| Machine | RAM | Price/month (always-on) |
|---------|-----|------------------------|
| shared-cpu-1x | 256 MB | ~$1.94 |
| shared-cpu-2x | 512 MB | ~$3.88 |
| shared-cpu-4x | 1 GB | ~$7.76 |
| performance-1x | 2 GB | ~$31.00 |
| performance-2x | 4 GB | ~$62.00 |
| performance-4x | 8 GB | ~$124.00 |
| performance-8x | 16 GB | ~$248.00 |

**Storage**: ~$0.15/GB/month volumes, ~$0.03/GB/month snapshots, ~$0.02/GB outbound (after 160 GB free).

**Free allowances (Hobby)**: 3 shared-cpu-1x VMs (256 MB), 3 GB volume storage, 160 GB transfer, shared IPv4 (dedicated: $2/month).

Check current rates: `https://fly.io/calculator`

## Troubleshooting

```bash
fly status --app my-app
fly ssh console --app my-app
fly ssh console --app my-app --command "env | grep -v SECRET"
fly logs --app my-app
fly machines list --app my-app          # Check if machines are stopped
fly machines start <machine-id> --app my-app
fly postgres connect --app my-app-db --database my_db
fly config validate --app my-app
```

## Helper Script

```bash
./.agents/scripts/fly-io-helper.sh deploy my-app
./.agents/scripts/fly-io-helper.sh scale my-app 3
./.agents/scripts/fly-io-helper.sh status my-app
./.agents/scripts/fly-io-helper.sh secrets my-app   # Names only, never values
./.agents/scripts/fly-io-helper.sh volumes my-app
./.agents/scripts/fly-io-helper.sh logs my-app
./.agents/scripts/fly-io-helper.sh apps
```

## References

- **Docs**: https://fly.io/docs/
- **Regions**: https://fly.io/docs/reference/regions/
- **Machines API**: https://fly.io/docs/machines/api/
- **Sprites**: https://fly.io/docs/machines/guides-examples/machines-api-app/
- **LiteFS**: https://fly.io/docs/litefs/
- **Community**: https://community.fly.io/
