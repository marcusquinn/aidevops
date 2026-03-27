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
- **Install**: `brew install orbstack` or <https://orbstack.dev/download>
- **CLI**: `orb` (management) + `docker` (Docker-compatible — existing commands work unmodified)
- **Docs**: <https://docs.orbstack.dev>
- **Status**: `orb status` | **Stop**: `orb stop` | **Start**: `orb start` | **Restart**: `orb restart`

**Why OrbStack over Docker Desktop**: Faster startup, lower memory, native macOS integration (Finder, menu bar, `.orb.local` domains), built-in Linux VMs, Rosetta x86 emulation on Apple Silicon, free for personal use.

<!-- AI-CONTEXT-END -->

## OrbStack-Specific Features

Standard `docker` and `docker compose` commands work without modification. These are OrbStack-only additions:

```bash
orb list                          # All containers and VMs
orb shell <container-name>        # Quick container shell access
curl http://my-app.orb.local      # Auto .orb.local DNS for containers
```

## Linux VMs

Lightweight Linux VMs alongside Docker:

```bash
orb create ubuntu my-ubuntu       # Create VM
orb shell my-ubuntu               # Shell into VM (or: ssh my-ubuntu@orb)
orb stop my-ubuntu                # Stop VM
orb start my-ubuntu               # Start VM
orb delete my-ubuntu              # Delete VM
```

VMs get automatic `.local` DNS, SSH access, and shared filesystem with macOS.

## OpenClaw Integration

```bash
# Setup
git clone https://github.com/openclaw/openclaw.git && cd openclaw
./docker-setup.sh                 # Builds image, runs onboarding, starts gateway
open http://127.0.0.1:18789/      # Control UI

# Management
docker compose ps                                    # Status
docker compose logs -f openclaw-gateway              # Logs
docker compose restart openclaw-gateway              # Restart
docker compose run --rm openclaw-cli doctor           # Health check
docker compose run --rm openclaw-cli security audit   # Security audit
docker compose run --rm openclaw-cli channels login   # Channel setup
```

**Persistent data** (survives container restarts/rebuilds):

| Path | Contents |
|------|----------|
| `~/.openclaw/openclaw.json` | Config |
| `~/.openclaw/workspace` | Workspace |
| `~/.openclaw/credentials/` | Credentials |
| `~/.openclaw/agents/<agentId>/sessions/` | Sessions |

## Common Use Cases

```bash
# Isolated dev database
docker run -d --name postgres -p 5432:5432 \
  -e POSTGRES_PASSWORD=dev postgres:16
# Access at postgres.orb.local or localhost:5432

# OpenClaw sandbox images
cd openclaw
scripts/sandbox-setup.sh           # Base sandbox
scripts/sandbox-common-setup.sh    # With build tools
scripts/sandbox-browser-setup.sh   # With Chromium
```

## Resource Management & Troubleshooting

```bash
orb status                        # Resource usage / health check
orb stop                          # Free memory when not needed
orb restart                       # Fix most issues
orb logs                          # OrbStack logs
orb reset                         # Factory reset (last resort)
docker system prune -a            # DESTRUCTIVE: removes all unused images/containers/networks
docker system df                  # Check disk usage
docker info                       # Docker daemon status
```

## Resources

- **Website**: <https://orbstack.dev> | **Docs**: <https://docs.orbstack.dev>
- **GitHub**: <https://github.com/orbstack/orbstack> | **Pricing**: Free personal, paid teams
