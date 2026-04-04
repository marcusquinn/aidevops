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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Uncloud Provider Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Multi-machine container orchestration (Docker-based, decentralised, no control plane)
- **CLI**: `uc` — commands: `status|machines|services|deploy|run|scale|logs|exec|inspect|volumes|dns|caddy|help`
- **Config**: `configs/uncloud-config.json` (copy from `configs/uncloud-config.json.txt`)
- **Helper**: `.agents/scripts/uncloud-helper.sh {status|machines|services|deploy|run|logs|scale}`
- **Docs**: <https://uncloud.run/docs> | **Source**: <https://github.com/psviderski/uncloud> (Apache-2.0, Go)
- **Status**: Active development, not yet production-ready (v0.16.0 as of Jan 2026)
- **Contexts**: `uc ctx ls && uc ctx use staging && uc ctx connection`

**Key features**: WireGuard mesh networking, Docker Compose format, Caddy reverse proxy with auto HTTPS (Let's Encrypt), Unregistry (registryless image push), managed DNS (`*.uncld.dev`), rolling deployments, ~150 MB RAM per machine daemon.

<!-- AI-CONTEXT-END -->

## Architecture

```text
uc CLI --SSH--> uncloudd daemon (Go)
               corrosion (CRDT/SQLite, peer-to-peer state sync by Fly.io)
               Docker + WireGuard mesh + Caddy proxy
```

Each machine runs `uncloudd`. Cluster state syncs peer-to-peer via corrosion — no control plane, no quorum. Security: WireGuard encrypts all inter-machine traffic; CLI communicates via SSH tunnels (only ports 22, 80, 443, 51820 needed).

## Installation

```bash
# macOS/Linux
brew install psviderski/tap/uncloud          # Homebrew
curl -fsS https://get.uncloud.run/install.sh | sh  # or curl

# Initialise first machine (installs Docker, uncloudd, WireGuard)
uc machine init root@your-server-ip

# Add more machines
uc machine add --name web-2 root@second-server-ip
```

## Cluster Configuration

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

## Service Management

```bash
uc run -p app.example.com:8000/https image/my-app   # run from image
uc deploy                                            # deploy from compose.yaml
uc ls                                                # list services
uc logs my-service                                   # view logs
uc exec my-service -- sh                             # exec into container
uc scale my-service 3                                # scale replicas
uc stop my-service && uc start my-service            # stop/start
uc rm my-service                                     # remove
```

## Machine Management

```bash
uc machine ls                                        # list machines
uc machine add --name node-3 root@third-server-ip    # add machine
uc machine rename old-name new-name                  # rename
uc machine rm node-3                                 # remove
uc machine update node-1 --ssh root@new-ip           # update SSH target
```

## Image, DNS, Caddy, Volume

```bash
# Unregistry — push local image directly (no external registry)
uc image push my-app:latest && uc image ls

# DNS
uc dns show && uc dns reserve && uc dns release

# Caddy
uc caddy config && uc caddy deploy

# Volumes
uc volume create my-data --machine web-1
uc volume ls && uc volume inspect my-data && uc volume rm my-data
```

## Compose File

Standard Docker Compose with deployment extensions:

```yaml
services:
  web:
    image: my-app:latest
    ports:
      - "app.example.com:8000/https"   # HTTPS with custom domain
      - "app.example.com:8000/http"    # HTTP only
      - "8080:8000/tcp"                # TCP
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

## Troubleshooting

```bash
# Machine init fails
ssh root@your-server-ip 'echo ok'                    # verify SSH
ssh root@your-server-ip 'docker info'                # check Docker
ssh root@your-server-ip 'systemctl status uncloud'   # check daemon

# Services not accessible
uc ls && uc inspect my-service                       # service status
uc caddy config                                      # Caddy config
uc wg show                                           # WireGuard connectivity
dig app.example.com                                  # DNS resolution

# Container networking
uc wg show && uc machine ls && uc ps

# Uninstall (run on the machine)
uncloud-uninstall
```
