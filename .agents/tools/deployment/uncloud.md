---
description: Lightweight multi-machine Docker deployment with Uncloud
mode: subagent
tools:
  read: true
  bash: true
---

# Uncloud

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Multi-machine Docker deployments without Kubernetes
- **Install**: `curl -fsSL https://get.uncloud.dev | sh` (Apache 2.0)
- **Repo**: <https://github.com/psviderski/uncloud>
- **Format**: Docker Compose (no new DSL)
- **Networking**: WireGuard mesh (zero-config, encrypted)

**Comparison with existing providers:**

| Provider | Type | Best For |
|----------|------|----------|
| Coolify | Self-hosted PaaS | Single-server apps, managed UI |
| Vercel | Serverless | Static sites, JAMstack, Next.js |
| **Uncloud** | Multi-machine orchestration | Cross-server Docker clusters |

<!-- AI-CONTEXT-END -->

## Key Features

- **Docker Compose format** - Use existing compose files, no migration
- **WireGuard mesh networking** - Automatic encrypted overlay network
- **No control plane** - Decentralized, no single point of failure
- **Built-in Caddy** - Reverse proxy with automatic HTTPS
- **Unregistry** - Push images directly to machines (no Docker Hub)
- **Service discovery** - Internal DNS for service-to-service communication
- **Managed DNS** - `*.uncld.dev` subdomains for quick access
- **Rolling deployments** - Zero-downtime updates

## CLI Commands

```bash
# Machine management
uc machine add <name> --ssh <user@host>    # Add a machine
uc machine ls                               # List machines
uc machine rm <name>                        # Remove a machine

# Deployment
uc deploy -f compose.yml                    # Deploy from compose file
uc deploy -f compose.yml --machine <name>   # Deploy to specific machine
uc ls                                       # List running services
uc logs <service>                           # View service logs
uc rm <service>                             # Remove a service

# Direct image push (no registry needed)
uc push <image> --machine <name>            # Push image to machine

# Networking
uc network ls                               # List networks
uc network inspect <name>                   # Inspect network
```

## Setup

```bash
# Install Uncloud CLI
curl -fsSL https://get.uncloud.dev -o /tmp/uncloud-install.sh
bash /tmp/uncloud-install.sh

# Add your first machine (any Linux server with Docker)
uc machine add prod-1 --ssh root@203.0.113.10

# Deploy a service
uc deploy -f docker-compose.yml
```

## Example Compose File

```yaml
services:
  web:
    image: nginx:alpine
    ports:
      - "80:80"
    deploy:
      replicas: 2
      placement:
        constraints:
          - node.labels.role == web

  api:
    image: myapp/api:latest
    environment:
      - DATABASE_URL=postgres://db:5432/app
    deploy:
      replicas: 3

  db:
    image: postgres:16
    volumes:
      - pgdata:/var/lib/postgresql/data
    deploy:
      placement:
        constraints:
          - node.labels.role == db

volumes:
  pgdata:
```

## When to Use

| Scenario | Recommendation |
|----------|---------------|
| Single server, want UI | Coolify |
| Static/JAMstack, want zero-ops | Vercel |
| Multi-server Docker, want simplicity | **Uncloud** |
| Enterprise, need full orchestration | Kubernetes |
| Dev/staging environments | Docker Compose (local) |

## Integration with aidevops

```bash
# Deploy from aidevops workflow
uc deploy -f docker-compose.yml --machine prod-1

# Check deployment status
uc ls

# View logs for debugging
uc logs myapp-api --follow
```

## Related

- `tools/deployment/coolify.md` - Self-hosted PaaS (single server)
- `tools/deployment/vercel.md` - Serverless deployment
- `services/hosting/localhost.md` - Local development
