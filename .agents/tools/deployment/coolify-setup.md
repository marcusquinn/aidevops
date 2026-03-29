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

# Coolify Setup Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Self-hosted alternative to Vercel/Netlify/Heroku
- **Install**: `curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash`
- **Requirements**: 2GB+ RAM (4GB+ recommended), Ubuntu 20.04+/Debian 11+, ports 22/80/443/8000
- **Dashboard**: `https://your-server-ip:8000`
- **Config**: `configs/coolify-config.json` (copy from `configs/coolify-config.json.txt`)
- **Operations**: See `coolify.md` for helper commands, monitoring, troubleshooting

<!-- AI-CONTEXT-END -->

## Installation

**Prerequisites:** SSH key, root/sudo access, domain pointing to server, DNS configured.

```bash
ssh root@your-server-ip
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash

# Verify
systemctl status coolify
docker logs coolify
```

### Firewall

```bash
ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw allow 8000/tcp && ufw enable
apt update && apt upgrade -y
apt install unattended-upgrades -y && dpkg-reconfigure -plow unattended-upgrades
```

## Initial Configuration

1. Open `https://your-server-ip:8000`
2. Create admin account
3. Add server details and domain
4. Generate SSH keys for Git access
5. Settings → API Tokens → create token

## Framework Configuration

```bash
cp configs/coolify-config.json.txt configs/coolify-config.json
```

Edit `configs/coolify-config.json`:

```json
{
  "servers": {
    "coolify-main": {
      "name": "Main Coolify Server",
      "host": "coolify.yourdomain.com",
      "ip": "your-server-ip",
      "coolify_url": "https://coolify.yourdomain.com",
      "ssh_key": "~/.ssh/id_ed25519"
    }
  },
  "api_configuration": {
    "main_server": {
      "api_token": "your-coolify-api-token",
      "base_url": "https://coolify.yourdomain.com/api/v1"
    }
  }
}
```

Add entries under `servers` for staging/prod environments.

## Deploying Applications

**Static site (React/Vue/Angular):** Create app → connect Git repo → build: `npm run build` → output: `dist` → domain → deploy.

**Node.js:** Create app → connect Git repo → start: `npm start` → env vars → port (3000) → domain → deploy.

**Database:** Databases → create (PostgreSQL/MySQL/MongoDB/Redis) → credentials → connect via env vars.

## Resources

- Docs: https://coolify.io/docs
- GitHub: https://github.com/coollabsio/coolify
- Discord: https://discord.gg/coolify
- Examples: https://github.com/coollabsio/coolify-examples
