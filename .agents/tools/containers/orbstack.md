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
- **Install**: `brew install orbstack` → verify with `orb status` and `docker --version`
- **CLI**: `orb` (management) + `docker` (Docker-compatible — all existing commands work unchanged)
- **Docs**: https://docs.orbstack.dev
- **Website**: https://orbstack.dev | **GitHub**: https://github.com/orbstack/orbstack
- **Pricing**: Free for personal use, paid for teams

**Why OrbStack over Docker Desktop**: Faster startup, lower memory, native macOS integration (Finder, menu bar, `.orb.local` domains), built-in Linux VMs, Rosetta x86 emulation on Apple Silicon.

<!-- AI-CONTEXT-END -->

## OrbStack-Specific Features

Standard `docker` and `docker compose` commands work without modification. These are OrbStack-only capabilities:

```bash
# Management
orb list                          # List all containers and VMs
orb shell <container-name>        # Quick shell access
orb stop                          # Stop OrbStack (frees resources)
orb start                         # Start OrbStack

# Automatic .local DNS — no config needed
curl http://<container-name>.orb.local
```

## Linux VMs

OrbStack runs lightweight Linux VMs alongside Docker with automatic `.orb.local` DNS, SSH, and shared filesystem:

```bash
orb create ubuntu my-ubuntu       # Create VM
orb shell my-ubuntu               # Shell into VM (or: ssh my-ubuntu@orb)
orb stop my-ubuntu                # Stop VM
orb start my-ubuntu               # Start VM
orb delete my-ubuntu              # Delete VM
```

## OpenClaw in OrbStack

### Setup

```bash
git clone https://github.com/openclaw/openclaw.git
cd openclaw
./docker-setup.sh                 # Builds image, runs onboarding, starts gateway
open http://127.0.0.1:18789/      # Access Control UI
```

### Management

```bash
docker compose ps                                    # Status
docker compose logs -f openclaw-gateway              # Logs
docker compose restart openclaw-gateway              # Restart
docker compose run --rm openclaw-cli doctor           # Health check
docker compose run --rm openclaw-cli security audit   # Security audit
docker compose run --rm openclaw-cli channels login   # Channel setup
```

### Persistent Data

Config and workspace are bind-mounted from the host (persist across container restarts):

| Path | Contents |
|------|----------|
| `~/.openclaw/openclaw.json` | Config |
| `~/.openclaw/workspace` | Workspace |
| `~/.openclaw/credentials/` | Credentials |
| `~/.openclaw/agents/<agentId>/sessions/` | Sessions |

## Common Use Cases

```bash
# Isolated dev database (access at postgres.orb.local or localhost:5432)
docker run -d --name postgres -p 5432:5432 \
  -e POSTGRES_PASSWORD=dev postgres:16

# OpenClaw sandbox images for agent tool isolation
cd openclaw
scripts/sandbox-setup.sh           # Base sandbox
scripts/sandbox-common-setup.sh    # With build tools
scripts/sandbox-browser-setup.sh   # With Chromium
```

## Troubleshooting

```bash
orb status                        # Check OrbStack status
orb restart                       # Restart OrbStack
orb logs                          # View OrbStack logs
docker info                       # Check Docker daemon
docker system prune -a            # Prune unused resources
docker system df                  # Check disk usage
orb reset                         # Factory reset (last resort)
```
