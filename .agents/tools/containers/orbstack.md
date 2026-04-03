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

- **Purpose**: Fast, lightweight Docker and Linux VM runtime for macOS; Docker Desktop replacement
- **Install**: `brew install orbstack` · verify: `orb status` and `docker --version`
- **CLI**: `orb` (management) + `docker` / `docker compose` (container workflows — all existing commands work unchanged)
- **Docs**: https://docs.orbstack.dev · https://orbstack.dev · https://github.com/orbstack/orbstack
- **Pricing**: Free for personal use, paid for teams
- **When to use**: Lower memory, faster startup, native macOS integration, `.orb.local` DNS, built-in Linux VMs, Rosetta x86 emulation on Apple Silicon

<!-- AI-CONTEXT-END -->

## Core Commands

Standard `docker` and `docker compose` commands work unchanged. Use `orb` for OrbStack-specific management:

```bash
orb list                          # List containers and VMs
orb shell <name>                  # Shell into a container or VM
orb start / orb stop              # Start / stop OrbStack
curl http://<container-name>.orb.local
```

## Linux VMs

Lightweight VMs with shared filesystem, SSH, and `.orb.local` networking:

```bash
orb create ubuntu my-ubuntu       # Create VM
orb shell my-ubuntu               # Shell into VM
ssh my-ubuntu@orb                 # SSH alternative
orb stop / orb start my-ubuntu    # Stop / start VM
orb delete my-ubuntu              # Delete VM
```

## OpenClaw Workflows

```bash
# Setup
git clone https://github.com/openclaw/openclaw.git && cd openclaw
./docker-setup.sh                 # Build image, run onboarding, start gateway
open http://127.0.0.1:18789/      # Access Control UI

# Routine management
docker compose ps                                     # Status
docker compose logs -f openclaw-gateway               # Logs
docker compose restart openclaw-gateway               # Restart gateway
docker compose run --rm openclaw-cli doctor           # Health check
docker compose run --rm openclaw-cli security audit   # Security audit
docker compose run --rm openclaw-cli channels login   # Channel setup
```

Persistent host data: `~/.openclaw/{openclaw.json,workspace,credentials/,agents/<agentId>/sessions/}`

## Common Use Cases

```bash
# Isolated dev database (postgres.orb.local or localhost:5432)
docker run -d --name postgres -p 5432:5432 -e POSTGRES_PASSWORD=dev postgres:16

# OpenClaw sandbox images for agent-tool isolation
scripts/sandbox-setup.sh           # Base sandbox
scripts/sandbox-common-setup.sh    # Adds build tools
scripts/sandbox-browser-setup.sh   # Adds Chromium
```

## Troubleshooting

```bash
orb status / orb restart / orb logs   # OrbStack status, restart, logs
docker info                           # Docker daemon info
docker system df                      # Disk usage
```

**Destructive ops:** `docker system prune -a` removes all unused containers, images, networks, and build cache. Prefer `docker image prune` or `docker container prune` unless a full reset is intended. `orb reset` is a factory reset — last resort.
