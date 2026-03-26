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
- **Script**: `.agents/scripts/fly-io-helper.sh [command] [app] [args]`
- **Config**: `fly.toml` (per-app, in repo root) | **Dashboard**: `https://fly.io/dashboard`
- **Docs**: `https://fly.io/docs/` | **Pricing**: `https://fly.io/docs/about/pricing/` | **Calculator**: `https://fly.io/calculator`
- **Key concepts**: Fly Machines (Firecracker micro-VMs), anycast routing, auto-stop/auto-start, Sprites (AI sandboxes), Tigris (S3-compatible storage)

<!-- AI-CONTEXT-END -->

Fly.io runs apps on Firecracker micro-VMs across 30+ regions with anycast routing. Best for latency-sensitive workloads, AI agent sandboxes (Sprites), and global apps needing auto-stop cost savings.

**Best for**: global low-latency apps, AI sandboxes, Elixir/Phoenix, full-stack, multi-region DBs (LiteFS/Fly Postgres), GPU inference.
**Not for**: serverless functions (Cloudflare Workers), static sites only (Cloudflare Pages), Kubernetes-native, Windows containers.

## fly.toml Configuration

```toml
app = "my-app-name"
primary_region = "lhr"              # Where volumes and primary Machine live

[build]
  dockerfile = "Dockerfile"

[env]
  PORT = "8080"
  NODE_ENV = "production"

[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = "stop"       # "stop" | "suspend" | true | false
  auto_start_machines = true        # Fly Proxy starts Machine on request
  min_machines_running = 0          # 0 = full auto-stop; 1+ = always-on

  [http_service.concurrency]
    type = "requests"
    hard_limit = 250
    soft_limit = 200

[[vm]]
  memory = "256mb"                  # 256mb-64gb
  cpu_kind = "shared"               # "shared" (burstable) | "performance" (dedicated)
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

GPU shorthand: `vm.size = "a100-40gb"` (or `a100-80gb`, `l40s`). Optional: `swap_size_mb = 32768`.

## Deployment

```bash
fly launch --name my-app --region lhr          # New app (creates fly.toml)
fly deploy                                      # Deploy current
fly deploy --image registry.fly.io/my-app:latest
fly deploy --strategy rolling --app my-app      # Or: canary
fly releases --app my-app                       # List releases (rollback: redeploy previous image)
fly status --app my-app && fly logs --app my-app
```

## Machines

Firecracker micro-VMs — sub-second start, billed per second.

```bash
fly machines list|start|stop|destroy <machine-id> --app my-app [--force]
fly ssh console --app my-app [--command "rails db:migrate"]
```

**REST API** — base: `https://api.machines.dev` (`FLY_API_HOSTNAME`), token: `fly tokens create` (`FLY_API_TOKEN`):

```bash
curl "${FLY_API_HOSTNAME}/v1/apps/{app}/machines[/{id}[/{action}]]" \
  -H "Authorization: Bearer ${FLY_API_TOKEN}" [-d '{"signal":"SIGTERM","timeout":"30s"}']
# Actions: start (POST), stop (POST), delete (DELETE)
```

## Compute Sizes and Pricing

| Size | CPU | RAM | ~$/month | Use case |
|------|-----|-----|----------|----------|
| `shared-cpu-1x` | 1 shared | 256 MB | $1.94 | Dev, low-traffic |
| `shared-cpu-2x` | 2 shared | 512 MB | $3.88 | Light production |
| `shared-cpu-4x` | 4 shared | 1 GB | $7.76 | Medium workloads |
| `performance-1x` | 1 dedicated | 2 GB | $31 | CPU-intensive |
| `performance-2x` | 2 dedicated | 4 GB | $62 | High-throughput |
| `performance-4x` | 4 dedicated | 8 GB | $124 | Heavy compute |
| `performance-8x` | 8 dedicated | 16 GB | $248 | AI inference |

**GPU**: `a100-40gb` (40 GB, ~$2.50/h), `a100-80gb` (80 GB, ~$3.50/h), `l40s` (48 GB, ~$2.00/h). Check: `fly platform vm-sizes`. Use auto-stop to avoid idle costs.

**Storage/transfer**: Volumes ~$0.15/GB/mo, snapshots ~$0.03/GB/mo, Tigris ~$0.02/GB/mo (free egress to Fly), outbound ~$0.02/GB (160 GB free).

**Free tier** (Hobby): 3 shared-cpu-1x VMs (256 MB), 3 GB volumes, 160 GB transfer, shared IPv4 (dedicated: $2/mo).

## Scaling

```bash
fly scale count 3 --app my-app                    # Horizontal
fly scale count 2 --region lhr --app my-app       # Per-region
fly scale vm performance-2x --app my-app          # Vertical
fly scale memory 1024 --app my-app
```

## Secrets

Encrypted at rest, injected as env vars, never in logs.

```bash
echo "value" | fly secrets set MY_SECRET=- --app my-app  # stdin — never as argument
fly secrets import --app my-app < .env.production
fly secrets list --app my-app                             # Names only
fly secrets unset MY_SECRET --app my-app
```

## Volumes (Persistent Storage)

NVMe SSDs, region-locked — a volume in `lhr` only attaches to Machines in `lhr`.

```bash
fly volumes create myapp_data --size 10 --region lhr --app my-app
fly volumes list --app my-app
fly volumes extend <vol-id> --size 20 --app my-app   # Increase only
fly volumes destroy <vol-id> --app my-app             # IRREVERSIBLE
fly volumes snapshots list --app my-app
```

For multi-region shared data, use Fly Postgres, LiteFS, or Tigris.

## Tigris Object Storage

S3-compatible global storage. `fly storage create` auto-sets: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT_URL_S3` (`https://fly.storage.tigris.dev`), `AWS_REGION` (`auto`), `BUCKET_NAME`. Use any S3 SDK — no code changes needed.

```bash
fly storage create | list | dashboard
```

## Databases

```bash
# Fly Postgres (managed, you handle upgrades)
fly postgres create --name my-db --region lhr
fly postgres attach my-db --app my-app         # Sets DATABASE_URL
fly postgres connect --app my-db

# Upstash Redis (serverless, pay per request)
fly redis create --name my-redis --region lhr
fly redis attach my-redis --app my-app         # Sets REDIS_URL
```

## Multi-Region

```bash
fly regions add|remove|list|backup iad --app my-app
```

Fly Postgres routes read replicas automatically. Set `PRIMARY_REGION` env var for write routing. Production: 2+ Machines with `min_machines_running = 1`.

## Networking

**Private**: All apps in same org share WireGuard mesh (6PN). Reach via `<app>.internal` (IPv6).

**Flycast** (private LB): `fly ips allocate-v6 --private --app my-svc` → access via `<app>.flycast`. Not internet-exposed.

## Sprites (AI Agent Sandboxes)

Isolated ephemeral Machines for untrusted AI agent code.

```bash
fly machines run my-image --app my-sprites-app --region lhr \
  --vm-size shared-cpu-1x --env AGENT_ID=agent-123 --restart no
```

**TypeScript SDK** (`@fly/sprites`) — mirrors `child_process` API:

```typescript
import { SpritesClient } from '@fly/sprites';
const sprite = new SpritesClient(process.env.SPRITES_TOKEN!).sprite('my-sprite');

const cmd = sprite.spawn('ls', ['-la']);                    // Event-based
const { stdout, exitCode } = await sprite.exec('echo hi');  // Promise-based

await sprite.updateNetworkPolicy({                          // Restrict network
  rules: [{ include: 'defaults' }, { domain: 'api.github.com', action: 'allow' }],
});
```

## Troubleshooting

```bash
fly status --app my-app                                       # Overview
fly logs --app my-app                                         # Logs
fly ssh console --app my-app --command "env | cut -d= -f1"    # Env key names only
fly config validate --app my-app                              # Validate fly.toml
```

## Helper Script

`fly-io-helper.sh <cmd> <app> [args]`: `deploy`, `scale <N>`, `status`, `secrets`, `volumes`, `logs`, `machines list`, `ssh`, `postgres <db> status`, `apps`.

## Related

- `tools/deployment/hosting-comparison.md` — Fly.io vs alternatives
- `.agents/scripts/fly-io-helper.sh` — helper script source

## References

- [Docs](https://fly.io/docs/) | [Regions](https://fly.io/docs/reference/regions/) | [Machines API](https://fly.io/docs/machines/api/)
- [Sprites SDK](https://github.com/superfly/sprites-js) | [Tigris](https://fly.io/docs/tigris/) | [LiteFS](https://fly.io/docs/litefs/)
- [Blueprints](https://fly.io/docs/blueprints/) | [Community](https://community.fly.io/)
