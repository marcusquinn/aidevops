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

## OrbStack-Specific Commands

Standard `docker` and `docker compose` commands work without modification. OrbStack-only:

```bash
orb list                          # List all containers and VMs
orb shell <container-name>        # Quick shell access
orb start / orb stop              # Start/stop OrbStack

# Automatic .orb.local DNS — no config needed
curl http://<container-name>.orb.local
```

## Linux VMs

Lightweight VMs alongside Docker with `.orb.local` DNS, SSH, and shared filesystem:

```bash
orb create ubuntu my-ubuntu       # Create VM
orb shell my-ubuntu               # Shell into VM (or: ssh my-ubuntu@orb)
orb stop my-ubuntu                # Stop VM
orb start my-ubuntu               # Start VM
orb delete my-ubuntu              # Delete VM
```

## Common Use Cases

```bash
# Isolated dev database (access at postgres.orb.local or localhost:5432)
docker run -d --name postgres -p 5432:5432 \
  -e POSTGRES_PASSWORD=dev postgres:16
```

## Troubleshooting

```bash
orb status                        # Check OrbStack status
orb restart                       # Restart OrbStack
orb logs                          # View OrbStack logs
docker info                       # Check Docker daemon
docker system df                  # Check disk usage
docker system prune -a            # DESTRUCTIVE: removes ALL unused resources
orb reset                         # Factory reset (last resort)
```
