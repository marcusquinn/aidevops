---
description: Coolify server installation and configuration
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Coolify Setup Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Self-hosted PaaS (Docker-based) — alternative to Vercel/Netlify/Heroku
- **Install**: `curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash`
- **Requirements**: 2GB+ RAM (4GB+ recommended), Ubuntu 20.04+/Debian 11+
- **Ports**: 22 (SSH), 80 (HTTP), 443 (HTTPS), 8000 (Coolify UI)
- **Dashboard**: `https://your-server-ip:8000`
- **Config**: `configs/coolify-config.json` (copy from `.json.txt` template)
- **Operations**: `coolify.md` (helper commands, monitoring, troubleshooting)
- **CLI**: `coolify-cli.md` (contexts, app/db management, CI/CD)

<!-- AI-CONTEXT-END -->

## Installation

**Prerequisites:** SSH key, root/sudo access, domain with DNS pointing to server.

```bash
ssh root@your-server-ip
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
systemctl status coolify --no-pager  # verify
ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw allow 8000/tcp && ufw --force enable
apt update && apt upgrade -y
apt install unattended-upgrades -y && dpkg-reconfigure -plow unattended-upgrades
```

## Initial Configuration

1. Open `https://your-server-ip:8000` → create admin account
2. Add server details and domain
3. Generate SSH keys for Git access
4. Settings → API Tokens → create token for framework integration

## Framework Configuration

```bash
cp configs/coolify-config.json.txt configs/coolify-config.json
```

Edit with your server host, ports, API token, and credentials. Config structure and multi-server setup: see `coolify.md` "Configuration" section.

## Deploying Applications

| Type | Key settings |
|------|-------------|
| **Static site** (React/Vue/Angular) | Build: `npm run build`, output: `dist`, set domain |
| **Node.js** | Start: `npm start`, set env vars, port (default 3000), set domain |
| **Database** | Databases → create (PostgreSQL/MySQL/MongoDB/Redis) → connect via env vars |

Workflow: push to Git → Coolify auto-deploys → health check → rollback if needed.

## Resources

- Docs: https://coolify.io/docs
- GitHub: https://github.com/coollabsio/coolify
