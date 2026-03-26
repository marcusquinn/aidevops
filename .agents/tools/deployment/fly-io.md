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

**Key concepts**: Fly Machines (Firecracker micro-VMs), anycast routing, auto-stop/start, Sprites (AI sandboxes), Tigris (S3-compatible object storage)

<!-- AI-CONTEXT-END -->

Fly.io runs apps on Firecracker micro-VMs (Fly Machines) across 30+ regions with anycast routing. Best for latency-sensitive workloads, AI agent sandboxes (Sprites), and global apps needing auto-stop cost savings.

**Best use cases**: global low-latency apps, AI agent sandboxes, Elixir/Phoenix, full-stack apps, cost-sensitive workloads, multi-region databases (LiteFS/Fly Postgres), GPU inference.

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
  auto_stop_machines = "stop"   # "stop" | "suspend" | true | false
  auto_start_machines = true    # Start on first request
  min_machines_running = 0      # 0 = full auto-stop; 1 = always-on

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
| `auto_stop_machines` | `"stop"`, `"suspend"`, `true`, `false` | `"stop"` = full stop; `"suspend"` = faster resume; `true` = legacy (same as `"stop"`) |
| `auto_start_machines` | `true`/`false` | Fly Proxy starts Machines on incoming request |
| `min_machines_running` | `0`-N | 0 = full auto-stop, 1+ = always-on |
| `cpu_kind` | `shared`, `performance` | Shared = burstable, Performance = dedicated |
| `memory` | `256mb`-`64gb` | RAM per Machine |
| `vm.size` | `a100-40gb`, `a100-80gb`, `l40s` | GPU preset (shorthand for `[[vm]]` section) |
| `swap_size_mb` | integer | Swap space in MB (useful for GPU workloads) |

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

### CLI Management

```bash
fly machines list --app my-app
fly machines start <machine-id> --app my-app
fly machines stop <machine-id> --app my-app
fly machines destroy <machine-id> --app my-app --force
fly ssh console --app my-app
fly ssh console --app my-app --command "rails db:migrate"
```

### Machines REST API

For programmatic control (CI/CD, custom orchestration):

```bash
# List all Machines
curl "${FLY_API_HOSTNAME}/v1/apps/my-app/machines" \
  -H "Authorization: Bearer ${FLY_API_TOKEN}"

# Start a stopped Machine
curl -X POST "${FLY_API_HOSTNAME}/v1/apps/my-app/machines/MACHINE_ID/start" \
  -H "Authorization: Bearer ${FLY_API_TOKEN}"

# Stop a running Machine (graceful)
curl -X POST "${FLY_API_HOSTNAME}/v1/apps/my-app/machines/MACHINE_ID/stop" \
  -H "Authorization: Bearer ${FLY_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"signal": "SIGTERM", "timeout": "30s"}'

# Delete a Machine permanently
curl -X DELETE "${FLY_API_HOSTNAME}/v1/apps/my-app/machines/MACHINE_ID" \
  -H "Authorization: Bearer ${FLY_API_TOKEN}"
```

API base: `https://api.machines.dev` (or `FLY_API_HOSTNAME` env var). Token: `fly tokens create` or `FLY_API_TOKEN`.

### Machine Sizes

| Size | CPU | RAM | Use case |
|------|-----|-----|----------|
| `shared-cpu-1x` | 1 shared | 256 MB | Dev, low-traffic |
| `shared-cpu-2x` | 2 shared | 512 MB | Light production |
| `shared-cpu-4x` | 4 shared | 1 GB | Medium workloads |
| `performance-1x` | 1 dedicated | 2 GB | CPU-intensive |
| `performance-2x` | 2 dedicated | 4 GB | High-throughput |
| `performance-4x` | 4 dedicated | 8 GB | Heavy compute |
| `performance-8x` | 8 dedicated | 16 GB | AI inference |

## GPU Machines

For ML inference, fine-tuning, and compute-heavy workloads. GPU Machines use dedicated hardware in specific regions.

```toml
# fly.toml — GPU configuration
app = "my-gpu-app"
primary_region = "ord"       # Ensure region offers GPUs
vm.size = "a100-40gb"        # GPU preset shorthand
swap_size_mb = 32768         # 32 GB swap for large models

[build]
  [build.args]
    NONROOT_USER = "mluser"

[mounts]
  source = "model_data"
  destination = "/home/mluser"
```

| GPU Size | GPU | VRAM | Use case |
|----------|-----|------|----------|
| `a100-40gb` | A100 | 40 GB | Large model inference, fine-tuning |
| `a100-80gb` | A100 | 80 GB | Very large models (70B+) |
| `l40s` | L40S | 48 GB | Inference, video processing |

```bash
# Deploy GPU app
fly deploy --app my-gpu-app

# Check GPU availability by region
fly platform vm-sizes
```

GPU Machines are billed per second of active time. Use auto-stop to avoid idle GPU costs.

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
fly volumes snapshots list --app my-app
```

Create volumes before deploying apps that need them. For multi-region shared data, use Fly Postgres, LiteFS, or Tigris instead.

## Tigris Object Storage

S3-compatible global object storage built on Fly.io infrastructure. Data is cached at edge locations for low-latency reads.

```bash
# Create a Tigris storage bucket (sets AWS_* secrets automatically)
fly storage create

# List buckets
fly storage list

# Dashboard
fly storage dashboard
```

Creating a bucket sets these secrets on the app:

- `AWS_ACCESS_KEY_ID` — Tigris access key
- `AWS_SECRET_ACCESS_KEY` — Tigris secret key
- `AWS_ENDPOINT_URL_S3` — `https://fly.storage.tigris.dev`
- `AWS_REGION` — `auto`
- `BUCKET_NAME` — bucket name

Use any S3-compatible SDK (AWS SDK, boto3, `@aws-sdk/client-s3`) with these credentials. No code changes needed if your app already uses S3.

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

### Resilient Multi-Machine Pattern

For production apps, run 2+ Machines with auto-stop to balance cost and availability:

```toml
[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = "stop"
  auto_start_machines = true
  min_machines_running = 1    # 1 always-on, extras auto-stop

  [http_service.concurrency]
    type = "requests"
    soft_limit = 200
```

## Networking

### Private Networking

All Fly apps in the same organization share a private WireGuard mesh (6PN). Apps communicate via `<app-name>.internal` DNS over IPv6.

```bash
# Connect to another app's internal service
curl http://my-other-app.internal:8080/api

# DNS lookup
dig aaaa my-other-app.internal
```

### Flycast (Private Load Balancing)

Allocate a private IPv6 address for internal-only services (not exposed to the internet):

```bash
fly ips allocate-v6 --private --app my-internal-service
```

Access via `<app-name>.flycast` from other apps in the same org.

## Sprites (AI Agent Sandboxes)

Isolated ephemeral Machines for running untrusted AI agent code. Two interfaces: CLI (quick) and SDK (programmatic).

### CLI (Quick Sandbox)

```bash
fly machines run my-sandbox-image \
  --app my-sprites-app \
  --region lhr \
  --vm-size shared-cpu-1x \
  --env AGENT_ID=agent-123 \
  --restart no

fly machines destroy <machine-id> --app my-sprites-app --force
```

### TypeScript SDK (`@fly/sprites`)

The SDK mirrors Node.js `child_process` API for remote command execution:

```typescript
import { SpritesClient } from '@fly/sprites';

const client = new SpritesClient(process.env.SPRITES_TOKEN!);
const sprite = client.sprite('my-sprite');

// Event-based (mirrors child_process.spawn)
const cmd = sprite.spawn('ls', ['-la']);
cmd.stdout.on('data', (chunk) => process.stdout.write(chunk));
cmd.on('exit', (code) => console.log(`Exited: ${code}`));

// Promise-based (mirrors child_process.exec)
const { stdout, stderr, exitCode } = await sprite.exec('echo hello');

// With environment and working directory
const result = await sprite.execFile('python', ['-c', 'print(2+2)'], {
  cwd: '/app',
  env: { MY_VAR: 'value' },
});
```

### Network Policies (Sandbox Security)

Control which domains a sprite can access:

```typescript
// Restrictive policy — allow only specific domains
await sprite.updateNetworkPolicy({
  rules: [
    { include: 'defaults' },
    { domain: 'api.github.com', action: 'allow' },
    { domain: '*.npmjs.org', action: 'allow' },
  ],
});

// Allow all (development only)
await sprite.updateNetworkPolicy({
  rules: [{ domain: '*', action: 'allow' }],
});
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

### Compute

| Machine | RAM | Price/month (always-on) |
|---------|-----|------------------------|
| shared-cpu-1x | 256 MB | ~$1.94 |
| shared-cpu-2x | 512 MB | ~$3.88 |
| shared-cpu-4x | 1 GB | ~$7.76 |
| performance-1x | 2 GB | ~$31.00 |
| performance-2x | 4 GB | ~$62.00 |
| performance-4x | 8 GB | ~$124.00 |
| performance-8x | 16 GB | ~$248.00 |

### GPU Compute

| GPU | VRAM | Price/hour |
|-----|------|------------|
| A100 40 GB | 40 GB | ~$2.50 |
| A100 80 GB | 80 GB | ~$3.50 |
| L40S | 48 GB | ~$2.00 |

### Storage and Transfer

- **Volumes**: ~$0.15/GB/month (NVMe SSD)
- **Snapshots**: ~$0.03/GB/month
- **Tigris**: ~$0.02/GB/month stored, free egress to Fly apps
- **Outbound transfer**: ~$0.02/GB (after 160 GB free)

### Free Allowances (Hobby Plan)

- 3 shared-cpu-1x VMs (256 MB each)
- 3 GB volume storage
- 160 GB outbound transfer
- Shared IPv4 (dedicated: $2/month)

Check current rates: `https://fly.io/calculator`

## Troubleshooting

```bash
fly status --app my-app
fly ssh console --app my-app
fly ssh console --app my-app --command "env | cut -d= -f1"  # Key names only
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
./.agents/scripts/fly-io-helper.sh machines my-app list
./.agents/scripts/fly-io-helper.sh ssh my-app
./.agents/scripts/fly-io-helper.sh postgres my-db-app status
```

## References

- **Docs**: https://fly.io/docs/
- **Regions**: https://fly.io/docs/reference/regions/
- **Machines API**: https://fly.io/docs/machines/api/
- **Sprites SDK**: https://github.com/superfly/sprites-js
- **Tigris**: https://fly.io/docs/tigris/
- **LiteFS**: https://fly.io/docs/litefs/
- **Blueprints**: https://fly.io/docs/blueprints/
- **Community**: https://community.fly.io/
