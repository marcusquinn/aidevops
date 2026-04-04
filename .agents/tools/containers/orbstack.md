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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# OrbStack - Container & VM Runtime

## Quick Reference

- **Purpose**: Fast, lightweight Docker and Linux VM runtime for macOS; Docker Desktop replacement
- **Install**: `brew install orbstack` · verify: `orb status` and `docker --version`
- **CLI**: `orb` (management) + `docker` / `docker compose` (container workflows — all existing commands work unchanged)
- **Docs**: https://docs.orbstack.dev · https://orbstack.dev · https://github.com/orbstack/orbstack
- **Pricing**: Free for personal use, paid for teams
- **When to use**: Lower memory, faster startup, native macOS integration, `.orb.local` DNS, built-in Linux VMs, Rosetta x86 emulation on Apple Silicon

## Core Commands

```bash
orb list                          # List containers and VMs
orb shell <name>                  # Shell into a container or VM
orb start / orb stop              # Start / stop OrbStack
curl http://<container-name>.orb.local

# Isolated dev database (postgres.orb.local or localhost:5432)
docker run -d --name postgres -p 5432:5432 -e POSTGRES_PASSWORD=dev postgres:16
```

## Linux VMs

```bash
orb create ubuntu my-ubuntu       # Create VM
orb shell my-ubuntu               # Shell into VM
ssh my-ubuntu@orb                 # SSH alternative
orb stop / orb start my-ubuntu    # Stop / start VM
orb delete my-ubuntu              # Delete VM
```

## Troubleshooting

```bash
orb status / orb restart / orb logs   # OrbStack status, restart, logs
docker info                           # Docker daemon info
docker system df                      # Disk usage
```

**Destructive ops:** `docker system prune -a` removes all unused containers, images, networks, and build cache. Prefer `docker image prune` or `docker container prune` unless a full reset is intended. `orb reset` is a factory reset — last resort.
