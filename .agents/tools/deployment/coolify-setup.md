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
- **Requirements**: 2GB+ RAM, Ubuntu 20.04+/Debian 11+, ports 22/80/443/8000
- **Dashboard**: `https://your-server-ip:8000`
- **Helper**: `.agents/scripts/coolify-helper.sh`
- **Commands**: `list` | `connect [server]` | `open [server]` | `status [server]` | `apps [server]` | `exec [server] [cmd]`
- **Config**: `configs/coolify-config.json`
- **Features**: Git deployments, databases (PostgreSQL/MySQL/MongoDB/Redis), SSL automation, Docker containers
- **Docs**: https://coolify.io/docs

<!-- AI-CONTEXT-END -->

## Prerequisites

**Server:** 2GB+ RAM (4GB+ recommended), Ubuntu 20.04+/Debian 11+, root/sudo access, domain pointing to server, ports 22/80/443/8000 open.

**Local:** SSH key, Git repositories, DNS configured.

## Installation

```bash
# Connect and install
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
5. Go to Settings → API Tokens → create token

## Framework Configuration

```bash
cp configs/coolify-config.json.txt configs/coolify-config.json
```

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

## Deploying Applications

**Static site (React/Vue/Angular):** Create app → connect Git repo → build command: `npm run build` → output dir: `dist` → configure domain → deploy.

**Node.js:** Create app → connect Git repo → start command: `npm start` → set env vars → port (usually 3000) → configure domain → deploy.

**Database:** Databases → create (PostgreSQL/MySQL/MongoDB/Redis) → configure credentials → connect via env vars.

## Helper Commands

```bash
# Server management
./.agents/scripts/coolify-helper.sh list
./.agents/scripts/coolify-helper.sh connect coolify-main
./.agents/scripts/coolify-helper.sh open coolify-main
./.agents/scripts/coolify-helper.sh status coolify-main

# Application and SSH
./.agents/scripts/coolify-helper.sh apps main_server
./.agents/scripts/coolify-helper.sh exec coolify-main 'docker ps'
./.agents/scripts/coolify-helper.sh generate-ssh-configs
ssh coolify-main  # after generate-ssh-configs
```

## Monitoring & Maintenance

```bash
# Health checks
./.agents/scripts/coolify-helper.sh exec coolify-main 'systemctl status coolify'
./.agents/scripts/coolify-helper.sh exec coolify-main 'docker ps'
./.agents/scripts/coolify-helper.sh exec coolify-main 'df -h'
./.agents/scripts/coolify-helper.sh exec coolify-main 'free -h'

# Logs
./.agents/scripts/coolify-helper.sh exec coolify-main 'docker logs coolify'
./.agents/scripts/coolify-helper.sh exec coolify-main 'journalctl -u coolify -f'
# Application logs: Coolify dashboard → Application → Logs tab
```

**Backups:** Configure automatic DB backups in Coolify; app code lives in Git; take regular VPS snapshots.

## Security

- SSH keys over passwords; restrict SSH to specific IPs
- Firewall: only ports 22/80/443/8000
- Enable automatic security updates
- Use env vars for secrets; HTTPS is automatic
- Strong DB passwords; rotate API tokens regularly

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Deployment fails | Build logs in dashboard; env vars; disk/memory |
| SSL issues | DNS points to server; ports 80/443 open; Let's Encrypt rate limits |
| App not accessible | App logs; port config; health check endpoint; `docker ps` |
| DB connection fails | DB running; connection string/credentials; container networking; DB logs |

## Resources

- Docs: https://coolify.io/docs
- GitHub: https://github.com/coollabsio/coolify
- Discord: https://discord.gg/coolify
- Examples: https://github.com/coollabsio/coolify-examples
