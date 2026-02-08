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

Uncloud is a lightweight clustering and container orchestration tool that deploys and manages containerised applications across a network of Docker hosts. It bridges the gap between Docker Compose and Kubernetes.

## Provider Overview

### Characteristics

- **Deployment Type**: Multi-machine container orchestration
- **Technology**: Docker containers + WireGuard mesh + distributed SQLite (Corrosion)
- **Format**: Docker Compose files (compose.yaml)
- **Networking**: Automatic WireGuard mesh with peer discovery and NAT traversal
- **Proxy**: Built-in Caddy reverse proxy with auto HTTPS (Let's Encrypt)
- **Architecture**: Decentralised, no control plane, no quorum
- **DNS**: Managed `*.uncld.dev` subdomains or custom domains
- **Images**: Direct push via Unregistry (no external registry needed)
- **Footprint**: ~150 MB RAM per machine daemon

### Best Use Cases

- **Multi-machine deployments** across cloud VMs, bare metal, hybrid setups
- **Outgrowing Docker Compose** with zero-downtime deployments and replicas
- **Self-hosting and homelabs** with simple scaling
- **Edge computing** with machines in different locations/providers
- **Dev/staging environments** mirroring production
- **Agencies** hosting multiple client projects on shared infrastructure

### Comparison with Other Providers

| Provider | Type | Best For |
|----------|------|----------|
| Coolify | Self-hosted PaaS | Single-server apps, managed UI experience |
| Vercel | Serverless | Static sites, JAMstack, Next.js |
| Cloudron | Self-hosted PaaS | App store experience, managed updates |
| **Uncloud** | **Multi-machine orchestration** | **Cross-server deployments, Docker clusters** |

## Configuration

### Setup Configuration

```bash
# Copy template
cp configs/uncloud-config.json.txt configs/uncloud-config.json

# Edit with your cluster details
```

### Cluster Configuration

```json
{
  "clusters": {
    "production": {
      "name": "Production Cluster",
      "context": "default",
      "machines": [
        {
          "name": "web-1",
          "ssh": "root@web1.example.com",
          "role": "general"
        }
      ]
    }
  }
}
```

## Installation

### CLI Installation

```bash
# macOS/Linux via Homebrew
brew install psviderski/tap/uncloud

# macOS/Linux via curl
curl -fsS https://get.uncloud.run/install.sh | sh
```

### Cluster Initialisation

```bash
# Initialise first machine (installs Docker, uncloudd, WireGuard)
uc machine init root@your-server-ip

# Add more machines
uc machine add --name web-2 root@second-server-ip

# List machines
uc machine ls
```

## Usage Examples

### Service Management

```bash
# Run a service from a Docker image
uc run -p app.example.com:8000/https image/my-app

# Deploy from a compose.yaml file
uc deploy

# List services
uc ls

# View service logs
uc logs my-service

# Execute command in a service container
uc exec my-service -- sh

# Scale a service
uc scale my-service 3

# Stop/start services
uc stop my-service
uc start my-service

# Remove a service
uc rm my-service
```

### Machine Management

```bash
# List machines in cluster
uc machine ls

# Add a machine
uc machine add --name node-3 root@third-server-ip

# Rename a machine
uc machine rename old-name new-name

# Remove a machine
uc machine rm node-3

# Update machine configuration
uc machine update node-1 --ssh root@new-ip
```

### Image Management (Unregistry)

```bash
# Push a local Docker image directly to cluster machines (no registry needed)
uc image push my-app:latest

# List images on cluster machines
uc image ls
```

### DNS Management

```bash
# Show cluster domain
uc dns show

# Reserve a cluster domain
uc dns reserve

# Release a cluster domain
uc dns release
```

### Caddy Reverse Proxy

```bash
# Show current Caddy configuration
uc caddy config

# Deploy/upgrade Caddy across all machines
uc caddy deploy
```

### Volume Management

```bash
# Create a volume on a specific machine
uc volume create my-data --machine web-1

# List volumes
uc volume ls

# Inspect a volume
uc volume inspect my-data

# Remove a volume
uc volume rm my-data
```

### Context Management (Multi-Cluster)

```bash
# List cluster contexts
uc ctx ls

# Switch to a different cluster
uc ctx use staging

# Change default connection for current context
uc ctx connection
```

## Compose File

Uncloud uses standard Docker Compose format with deployment extensions:

```yaml
services:
  web:
    image: my-app:latest
    ports:
      - "app.example.com:8000/https"
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

### Port Publishing Formats

```yaml
ports:
  # HTTPS with custom domain
  - "app.example.com:8000/https"
  # HTTP only
  - "app.example.com:8000/http"
  # TCP port (host:container)
  - "8080:8000/tcp"
  # UDP port
  - "53:53/udp"
```

## Helper Script

The `uncloud-helper.sh` script wraps common `uc` CLI operations:

```bash
# Check cluster status
./.agents/scripts/uncloud-helper.sh status

# List machines
./.agents/scripts/uncloud-helper.sh machines

# List services
./.agents/scripts/uncloud-helper.sh services

# Deploy from compose.yaml
./.agents/scripts/uncloud-helper.sh deploy

# Run a service
./.agents/scripts/uncloud-helper.sh run my-app:latest -p app.example.com:8000/https

# View logs
./.agents/scripts/uncloud-helper.sh logs my-service

# Scale a service
./.agents/scripts/uncloud-helper.sh scale my-service 3
```

## Troubleshooting

### Common Issues

**Machine init fails:**

```bash
# Verify SSH access
ssh root@your-server-ip 'echo ok'

# Check Docker is running
ssh root@your-server-ip 'docker info'

# Check uncloudd service
ssh root@your-server-ip 'systemctl status uncloud'
```

**Services not accessible:**

```bash
# Check service status
uc ls
uc inspect my-service

# Check Caddy config
uc caddy config

# Check WireGuard connectivity
uc wg show

# Verify DNS
dig app.example.com
```

**Container networking issues:**

```bash
# Check WireGuard mesh
uc wg show

# Verify machine connectivity
uc machine ls

# Check container IPs
uc ps
```

### Uninstalling

```bash
# Uninstall Uncloud from a machine (run on the machine)
uncloud-uninstall
```

## Security

- **WireGuard encryption**: All inter-machine traffic encrypted
- **SSH-based management**: CLI communicates via SSH tunnels
- **No exposed ports**: Only SSH (22), HTTP (80), HTTPS (443), WireGuard (51820) needed
- **Container isolation**: Standard Docker container isolation
- **Auto HTTPS**: Let's Encrypt certificates via Caddy

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

- **uncloudd**: Machine daemon (Go binary) managing containers and cluster state
- **corrosion**: CRDT-based distributed SQLite for peer-to-peer state sync (by Fly.io)
- **WireGuard**: Encrypted mesh network with automatic peer discovery
- **Caddy**: Reverse proxy running globally on all machines, auto-configures from cluster state
