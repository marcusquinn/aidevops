---
description: OrbStack - Fast Docker and Linux VM runtime for macOS
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

# OrbStack - Container & VM Runtime

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Install**: `brew install orbstack` or https://orbstack.dev/download
- **CLI**: `orb` (management) + `docker` (Docker-compatible)
- **Docs**: https://docs.orbstack.dev | **Status**: `orb status`

**Why OrbStack over Docker Desktop**: faster startup, lower memory, native macOS integration (`.local` domains, menu bar), built-in Linux VMs, Rosetta x86 emulation on Apple Silicon, free for personal use.

<!-- AI-CONTEXT-END -->

## Docker Operations

```bash
# Standard Docker commands work unchanged
docker run -d --name my-app -p 8080:80 nginx
docker ps && docker logs my-app && docker stop my-app

# Docker Compose
docker compose up -d && docker compose logs -f && docker compose down

# OrbStack extras
orb list                        # list containers + VMs
orb shell <container-name>      # quick shell access
curl http://my-app.orb.local    # automatic .local domains
orb stop / orb start            # free/restore resources
```

## Linux VMs

```bash
orb create ubuntu my-ubuntu     # create VM
orb shell my-ubuntu             # shell (or: ssh my-ubuntu@orb)
orb stop my-ubuntu / orb start my-ubuntu
orb delete my-ubuntu
```

VMs get automatic `.local` DNS, SSH access, and shared filesystem with macOS.

## OpenClaw in OrbStack

```bash
# Setup
git clone https://github.com/openclaw/openclaw.git && cd openclaw
./docker-setup.sh               # builds image, runs onboarding, starts gateway
open http://127.0.0.1:18789/    # Control UI

# Manage
docker compose ps
docker compose logs -f openclaw-gateway
docker compose restart openclaw-gateway
docker compose run --rm openclaw-cli doctor
docker compose run --rm openclaw-cli security audit
docker compose run --rm openclaw-cli channels login
```

**Persistent data** (bind-mounted, survives restarts/rebuilds):

- Config: `~/.openclaw/openclaw.json`
- Workspace: `~/.openclaw/workspace`
- Credentials: `~/.openclaw/credentials/`
- Sessions: `~/.openclaw/agents/<agentId>/sessions/`

## Common Use Cases with aidevops

```bash
# 1. Isolated dev database
docker run -d --name postgres -p 5432:5432 \
  -e POSTGRES_PASSWORD=dev postgres:16
# Access at postgres.orb.local or localhost:5432

# 2. OpenClaw sandbox images
cd openclaw
scripts/sandbox-setup.sh           # base sandbox
scripts/sandbox-common-setup.sh    # with build tools
scripts/sandbox-browser-setup.sh   # with Chromium

# 3. Test Coolify locally before VPS deployment
docker run -d --name coolify -p 8000:8000 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  coollabsio/coolify:latest

# 4. Resource cleanup
docker system prune -a && docker system df
```

## Troubleshooting

```bash
orb status          # check state
orb restart         # restart daemon
orb logs            # daemon logs
orb reset           # last resort — full reset
docker info         # Docker daemon details
```
