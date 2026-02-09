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

- **Purpose**: Fast, lightweight Docker and Linux VM runtime for macOS (replaces Docker Desktop)
- **Install**: `brew install orbstack` or https://orbstack.dev/download
- **CLI**: `orb` (management) + `docker` (Docker-compatible)
- **Docs**: https://docs.orbstack.dev
- **Status**: `orb status`

**Why OrbStack over Docker Desktop**:

- Significantly faster startup and lower memory usage
- Native macOS integration (Finder, menu bar, `.local` domains)
- Built-in Linux VMs alongside Docker containers
- Rosetta x86 emulation on Apple Silicon
- Free for personal use

<!-- AI-CONTEXT-END -->

## Installation

```bash
# Via Homebrew (recommended)
brew install orbstack

# Verify
orb status
docker --version
```

OrbStack provides a Docker-compatible CLI. Existing `docker` and `docker compose` commands work without modification.

## Docker Operations

### Running Containers

```bash
# Standard Docker commands work
docker run -d --name my-app -p 8080:80 nginx
docker ps
docker logs my-app
docker stop my-app

# Docker Compose
docker compose up -d
docker compose logs -f
docker compose down
```

### OrbStack-Specific Features

```bash
# List all containers and VMs
orb list

# Quick access to container shell
orb shell <container-name>

# Container .local domains (automatic)
# Access containers at <container-name>.orb.local
curl http://my-app.orb.local

# Stop OrbStack (frees resources)
orb stop

# Start OrbStack
orb start
```

## Linux VMs

OrbStack can run lightweight Linux VMs alongside Docker:

```bash
# Create an Ubuntu VM
orb create ubuntu my-ubuntu

# SSH into VM
orb shell my-ubuntu

# Or use SSH directly
ssh my-ubuntu@orb

# List VMs
orb list

# Stop/start VM
orb stop my-ubuntu
orb start my-ubuntu

# Delete VM
orb delete my-ubuntu
```

VMs get automatic `.local` DNS, SSH access, and shared filesystem with macOS.

## OpenClaw in OrbStack

### Running OpenClaw via Docker

```bash
# Clone OpenClaw
git clone https://github.com/openclaw/openclaw.git
cd openclaw

# Run setup (builds image, runs onboarding, starts gateway)
./docker-setup.sh

# Access Control UI
open http://127.0.0.1:18789/
```

### Managing the OpenClaw Container

```bash
# Check status
docker compose ps

# View logs
docker compose logs -f openclaw-gateway

# Restart gateway
docker compose restart openclaw-gateway

# Run CLI commands
docker compose run --rm openclaw-cli doctor
docker compose run --rm openclaw-cli security audit

# Channel setup
docker compose run --rm openclaw-cli channels login
```

### Persistent Data

OpenClaw config and workspace are bind-mounted from the host:

- Config: `~/.openclaw/openclaw.json`
- Workspace: `~/.openclaw/workspace`
- Credentials: `~/.openclaw/credentials/`
- Sessions: `~/.openclaw/agents/<agentId>/sessions/`

These persist across container restarts and rebuilds.

## Common Use Cases with aidevops

### 1. Isolated Development Environments

```bash
# Run a database for local development
docker run -d --name postgres -p 5432:5432 \
  -e POSTGRES_PASSWORD=dev postgres:16

# Access at postgres.orb.local or localhost:5432
```

### 2. OpenClaw Sandbox Images

Build sandbox images for OpenClaw agent tool isolation:

```bash
cd openclaw
scripts/sandbox-setup.sh           # Base sandbox
scripts/sandbox-common-setup.sh    # With build tools
scripts/sandbox-browser-setup.sh   # With Chromium
```

### 3. Testing Coolify Locally

```bash
# Run Coolify in Docker for local testing before VPS deployment
docker run -d --name coolify -p 8000:8000 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  coollabsio/coolify:latest
```

## Resource Management

```bash
# Check OrbStack resource usage
orb status

# Stop OrbStack when not needed (frees memory)
orb stop

# Prune unused Docker resources
docker system prune -a

# Check disk usage
docker system df
```

## Troubleshooting

```bash
# Check OrbStack status
orb status

# Restart OrbStack
orb restart

# Check Docker daemon
docker info

# View OrbStack logs
orb logs

# Reset OrbStack (last resort)
orb reset
```

## Resources

- **Website**: https://orbstack.dev
- **Docs**: https://docs.orbstack.dev
- **GitHub**: https://github.com/orbstack/orbstack
- **Pricing**: Free for personal use, paid for teams
