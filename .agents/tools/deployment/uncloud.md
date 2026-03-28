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
- **Source**: https://github.com/psviderski/uncloud (Apache-2.0, Go)
- **Status**: Active development, not yet production-ready (v0.16.0 as of Jan 2026)
- **Stack**: Docker + WireGuard mesh + Corrosion (CRDT SQLite) + Caddy (auto HTTPS)
- **Key features**: No control plane, Docker Compose format, Unregistry (registryless image push), managed DNS (*.uncld.dev), rolling deployments

<!-- AI-CONTEXT-END -->

## Configuration

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

```bash
# macOS/Linux via Homebrew
brew install psviderski/tap/uncloud

# macOS/Linux via curl
curl -fsS https://get.uncloud.run/install.sh | sh

# Initialise first machine (installs Docker, uncloudd, WireGuard)
uc machine init root@your-server-ip

# Add more machines
uc machine add --name web-2 root@second-server-ip

# List machines
uc machine ls
```

## Usage

### Services

```bash
uc run -p app.example.com:8000/https image/my-app   # Run from image
uc deploy                                             # Deploy from compose.yaml
uc ls                                                 # List services
uc logs my-service                                    # View logs
uc exec my-service -- sh                              # Shell into container
uc scale my-service 3                                 # Scale replicas
uc stop my-service                                    # Stop
uc start my-service                                   # Start
uc rm my-service                                      # Remove
```

### Machines

```bash
uc machine ls                                         # List
uc machine add --name node-3 root@third-server-ip     # Add
uc machine rename old-name new-name                   # Rename
uc machine rm node-3                                  # Remove
uc machine update node-1 --ssh root@new-ip            # Update config
```

### Images (Unregistry)

```bash
uc image push my-app:latest                           # Push directly (no registry)
uc image ls                                           # List on cluster
```

### DNS

```bash
uc dns show                                           # Show cluster domain
uc dns reserve                                        # Reserve *.uncld.dev domain
uc dns release                                        # Release domain
```

### Caddy Reverse Proxy

```bash
uc caddy config                                       # Show config
uc caddy deploy                                       # Deploy/upgrade across machines
```

### Volumes

```bash
uc volume create my-data --machine web-1              # Create on specific machine
uc volume ls                                          # List
uc volume inspect my-data                             # Inspect
uc volume rm my-data                                  # Remove
```

### Contexts (Multi-Cluster)

```bash
uc ctx ls                                             # List clusters
uc ctx use staging                                    # Switch cluster
uc ctx connection                                     # Change default connection
```

## Compose File

Standard Docker Compose format with deployment extensions:

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
  - "app.example.com:8000/https"    # HTTPS with custom domain
  - "app.example.com:8000/http"     # HTTP only
  - "8080:8000/tcp"                 # TCP (host:container)
  - "53:53/udp"                     # UDP
```

## Helper Script

`.agents/scripts/uncloud-helper.sh` wraps common `uc` operations:

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
ssh root@your-server-ip 'echo ok'              # Verify SSH
ssh root@your-server-ip 'docker info'           # Check Docker
ssh root@your-server-ip 'systemctl status uncloud'  # Check daemon
```

**Services not accessible:**

```bash
uc ls && uc inspect my-service                  # Service status
uc caddy config                                 # Caddy config
uc wg show                                      # WireGuard connectivity
dig app.example.com                             # DNS resolution
```

**Container networking issues:**

```bash
uc wg show                                      # WireGuard mesh
uc machine ls                                   # Machine connectivity
uc ps                                           # Container IPs
```

**Uninstall:** Run `uncloud-uninstall` on the target machine.

## Security

- All inter-machine traffic encrypted via WireGuard
- CLI communicates via SSH tunnels
- Only SSH (22), HTTP (80), HTTPS (443), WireGuard (51820) exposed
- Auto HTTPS via Let's Encrypt (Caddy)
- Standard Docker container isolation

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
- **WireGuard**: Encrypted mesh with automatic peer discovery
- **Caddy**: Reverse proxy on all machines, auto-configures from cluster state
