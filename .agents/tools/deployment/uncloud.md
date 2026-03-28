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
- **Config**: `configs/uncloud-config.json` (copy from `configs/uncloud-config.json.txt`)
- **Script**: `.agents/scripts/uncloud-helper.sh`
- **Docs**: https://uncloud.run/docs
- **Source**: https://github.com/psviderski/uncloud (Apache-2.0, Go)
- **Status**: Active development, not yet production-ready (v0.16.0 as of Jan 2026)
- **Commands**: `status|machines|services|deploy|run|scale|logs|exec|inspect|volumes|dns|caddy|help`

**Key features**: WireGuard mesh networking, Docker Compose format, no control plane, Caddy reverse proxy with auto HTTPS, Unregistry (registryless image push), managed DNS (`*.uncld.dev`), rolling deployments, ~150 MB RAM per machine daemon.

<!-- AI-CONTEXT-END -->

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
uc image push my-app:latest
uc image ls

# DNS
uc dns show && uc dns reserve && uc dns release

# Caddy
uc caddy config && uc caddy deploy

# Volumes
uc volume create my-data --machine web-1
uc volume ls && uc volume inspect my-data && uc volume rm my-data
```

## Multi-Cluster Contexts

```bash
uc ctx ls && uc ctx use staging && uc ctx connection
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
ssh root@your-server-ip 'echo ok'                    # verify SSH
ssh root@your-server-ip 'docker info'                # check Docker
ssh root@your-server-ip 'systemctl status uncloud'   # check daemon
```

**Services not accessible:**

```bash
uc ls && uc inspect my-service   # service status
uc caddy config                  # Caddy config
uc wg show                       # WireGuard connectivity
dig app.example.com              # DNS
```

**Container networking:**

```bash
uc wg show && uc machine ls && uc ps
```

**Uninstall:**

```bash
uncloud-uninstall   # run on the machine
```

## Security

- WireGuard encrypts all inter-machine traffic
- CLI communicates via SSH tunnels — only SSH (22), HTTP (80), HTTPS (443), WireGuard (51820) needed
- Auto HTTPS via Let's Encrypt (Caddy)

## Architecture

```text
uc CLI --SSH--> uncloudd daemon (Go)
               corrosion (CRDT/SQLite, peer-to-peer state sync by Fly.io)
               Docker + WireGuard mesh + Caddy proxy
```

Each machine runs `uncloudd`. Cluster state syncs peer-to-peer via corrosion. No control plane, no quorum.
