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

| Item | Details |
|------|---------|
| Purpose | Fast, lightweight Docker and Linux VM runtime for macOS; practical Docker Desktop replacement |
| Install | `brew install orbstack` then verify with `orb status` and `docker --version` |
| CLI | `orb` for OrbStack management, `docker` / `docker compose` for normal container workflows |
| Docs | https://docs.orbstack.dev |
| Links | https://orbstack.dev · https://github.com/orbstack/orbstack |
| Pricing | Free for personal use, paid for teams |

Prefer OrbStack when you want lower memory use, faster startup, native macOS integration, automatic `.orb.local` DNS, built-in Linux VMs, or Rosetta-based x86 emulation on Apple Silicon.

<!-- AI-CONTEXT-END -->

## Core Commands

Standard `docker` and `docker compose` commands work unchanged. Use `orb` for OrbStack-specific management:

```bash
orb list                          # List containers and VMs
orb shell <name>                  # Quick shell into a container or VM
orb start                         # Start OrbStack
orb stop                          # Stop OrbStack and free resources
curl http://<container-name>.orb.local
```

## Linux VMs

OrbStack can run lightweight Linux VMs with shared filesystem access, SSH, and `.orb.local` networking:

```bash
orb create ubuntu my-ubuntu       # Create VM
orb shell my-ubuntu               # Shell into VM
ssh my-ubuntu@orb                 # SSH alternative
orb stop my-ubuntu                # Stop VM
orb start my-ubuntu               # Start VM
orb delete my-ubuntu              # Delete VM
```

## OpenClaw Workflows

### Setup

```bash
git clone https://github.com/openclaw/openclaw.git
cd openclaw
./docker-setup.sh                 # Build image, run onboarding, start gateway
open http://127.0.0.1:18789/      # Access Control UI
```

### Routine Management

```bash
docker compose ps                                     # Status
docker compose logs -f openclaw-gateway               # Logs
docker compose restart openclaw-gateway               # Restart gateway
docker compose run --rm openclaw-cli doctor           # Health check
docker compose run --rm openclaw-cli security audit   # Security audit
docker compose run --rm openclaw-cli channels login   # Channel setup
```

### Persistent Host Data

| Path | Purpose |
|------|---------|
| `~/.openclaw/openclaw.json` | Config |
| `~/.openclaw/workspace` | Workspace |
| `~/.openclaw/credentials/` | Credentials |
| `~/.openclaw/agents/<agentId>/sessions/` | Sessions |

## Common Use Cases

```bash
# Isolated dev database at postgres.orb.local or localhost:5432
docker run -d --name postgres -p 5432:5432 \
  -e POSTGRES_PASSWORD=dev postgres:16

# OpenClaw sandbox images for agent-tool isolation
cd openclaw
scripts/sandbox-setup.sh           # Base sandbox
scripts/sandbox-common-setup.sh    # Adds build tools
scripts/sandbox-browser-setup.sh   # Adds Chromium
```

## Troubleshooting

```bash
orb status                        # Check OrbStack status
orb restart                       # Restart OrbStack
orb logs                          # View OrbStack logs
docker info                       # Check Docker daemon
docker system df                  # Check Docker disk usage
```

`docker system prune -a` is destructive: it permanently removes all unused containers, images, networks, and build cache. Prefer `docker image prune`, `docker container prune`, or dropping `-a` unless you explicitly want a full reset.

```bash
docker system prune -a            # Full destructive cleanup
orb reset                         # Factory reset; last resort
```
