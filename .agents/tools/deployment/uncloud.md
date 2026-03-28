---
description: Lightweight multi-machine container orchestration with Uncloud
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

# Uncloud Provider Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Multi-machine container orchestration (Docker-based, decentralised)
- **CLI**: `uc` (install: `brew install psviderski/tap/uncloud` or `curl -fsS https://get.uncloud.run/install.sh | sh`)
- **Config**: `configs/uncloud-config.json`
- **Script**: `.agents/scripts/uncloud-helper.sh`
- **Docs**: https://uncloud.run/docs
- **Source**: https://github.com/psviderski/uncloud (Apache-2.0, 4.6k stars, Go)
- **Status**: Active development, not yet production-ready (v0.16.0 as of Jan 2026)
- **Commands**: `status|machines|services|deploy|run|scale|logs|exec|inspect|volumes|dns|caddy|help`
- **Usage**: `./.agents/scripts/uncloud-helper.sh [command] [args]`

**Key features**: WireGuard mesh networking, Docker Compose format, no control plane, Caddy reverse proxy with auto HTTPS, Unregistry (registryless image push), managed DNS (*.uncld.dev), rolling deployments.

<!-- AI-CONTEXT-END -->

Uncloud deploys and manages containerised applications across Docker hosts. Bridges Docker Compose and Kubernetes — decentralised, no control plane, ~150 MB RAM per machine daemon.

**Best for**: Multi-machine deployments, outgrowing Docker Compose, self-hosting/homelabs, edge computing, agencies hosting multiple clients.

| Provider | Type | Best For |
|----------|------|----------|
| Coolify | Self-hosted PaaS | Single-server apps, managed UI |
| Vercel | Serverless | Static sites, JAMstack, Next.js |
| Cloudron | Self-hosted PaaS | App store experience, managed updates |
| **Uncloud** | **Multi-machine orchestration** | **Cross-server deployments, Docker clusters** |

## Installation & Setup

```bash
# Install CLI
brew install psviderski/tap/uncloud
# or
curl -fsS https://get.uncloud.run/install.sh | sh

# Initialise first machine (installs Docker, uncloudd, WireGuard)
uc machine init root@your-server-ip

# Add more machines
uc machine add --name web-2 root@second-server-ip
uc machine ls
```

### Cluster Config (`configs/uncloud-config.json`)

```bash
cp configs/uncloud-config.json.txt configs/uncloud-config.json
```

```json
{
  "clusters": {
    "production": {
      "name": "Production Cluster",
      "context": "default",
      "machines": [
        { "name": "web-1", "ssh": "root@web1.example.com", "role": "general" }
      ]
    }
  }
}
```

## Usage

### Services

```bash
uc run -p app.example.com:8000/https image/my-app  # run from image
uc deploy                                           # deploy from compose.yaml
uc ls                                               # list services
uc logs my-service
uc exec my-service -- sh
uc scale my-service 3
uc stop my-service && uc start my-service
uc rm my-service
uc inspect my-service
```

### Machines

```bash
uc machine ls
uc machine add --name node-3 root@third-server-ip
uc machine rename old-name new-name
uc machine rm node-3
uc machine update node-1 --ssh root@new-ip
```

### Images (Unregistry — no external registry needed)

```bash
uc image push my-app:latest   # push local image directly to cluster
uc image ls
```

### DNS, Caddy, Volumes, Contexts

```bash
# DNS
uc dns show && uc dns reserve && uc dns release

# Caddy reverse proxy
uc caddy config && uc caddy deploy

# Volumes
uc volume create my-data --machine web-1
uc volume ls && uc volume inspect my-data && uc volume rm my-data

# Multi-cluster contexts
uc ctx ls && uc ctx use staging && uc ctx connection
```

## Compose File

```yaml
services:
  web:
    image: my-app:latest
    ports:
      - "app.example.com:8000/https"   # HTTPS with custom domain
      - "app.example.com:8000/http"    # HTTP only
      - "8080:8000/tcp"                # TCP (host:container)
      - "53:53/udp"                    # UDP
    deploy:
      replicas: 2
      update_config:
        parallelism: 1
        order: start-first
    volumes:
      - app-data:/data

volumes:
  app-data:
```

## Helper Script

```bash
./.agents/scripts/uncloud-helper.sh status
./.agents/scripts/uncloud-helper.sh machines
./.agents/scripts/uncloud-helper.sh services
./.agents/scripts/uncloud-helper.sh deploy
./.agents/scripts/uncloud-helper.sh run my-app:latest -p app.example.com:8000/https
./.agents/scripts/uncloud-helper.sh logs my-service
./.agents/scripts/uncloud-helper.sh scale my-service 3
```

## Troubleshooting

**Machine init fails:**

```bash
ssh root@your-server-ip 'echo ok'                  # verify SSH
ssh root@your-server-ip 'docker info'              # check Docker
ssh root@your-server-ip 'systemctl status uncloud' # check daemon
```

**Services not accessible:**

```bash
uc ls && uc inspect my-service  # service status
uc caddy config                 # Caddy config
uc wg show                      # WireGuard connectivity
dig app.example.com             # DNS
```

**Container networking:**

```bash
uc wg show && uc machine ls && uc ps
```

**Uninstall** (run on the machine): `uncloud-uninstall`

## Security

- WireGuard encryption for all inter-machine traffic
- SSH-based management (CLI via SSH tunnels)
- Only ports needed: SSH (22), HTTP (80), HTTPS (443), WireGuard (51820)
- Auto HTTPS via Let's Encrypt (Caddy)

## Architecture

```text
Local Machine                    Remote Machines
+------------------+             +------------------+
| uc CLI           |---SSH--->   | uncloudd daemon  |
+------------------+             | corrosion (CRDT) |
                                 | Docker           |
                                 | WireGuard        |
                                 | Caddy proxy      |
                                 +------------------+
                                        |
                                   WireGuard mesh
                                        |
                                 +------------------+
                                 | uncloudd daemon  |
                                 | corrosion (CRDT) |
                                 | Docker           |
                                 | WireGuard        |
                                 | Caddy proxy      |
                                 +------------------+
```

- **uncloudd**: Machine daemon (Go) managing containers and cluster state
- **corrosion**: CRDT-based distributed SQLite for peer-to-peer state sync (by Fly.io)
- **WireGuard**: Encrypted mesh network with automatic peer discovery
- **Caddy**: Reverse proxy on all machines, auto-configures from cluster state
