---
description: Self-hosted PaaS deployment with Coolify
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

# Coolify Provider Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Self-hosted PaaS (Docker-based)
- **Install**: `curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash`
- **Access**: `https://server-ip:8000`
- **Config**: `configs/coolify-config.json`
- **Commands**: `coolify-helper.sh [list|connect|open|status|apps|exec] [server] [args]`
- **Features**: Auto SSL, GitHub/GitLab/Bitbucket integration, PostgreSQL/MySQL/MongoDB/Redis
- **SSH**: Ed25519 keys recommended
- **Ports**: 22 (SSH), 80 (HTTP), 443 (HTTPS), 8000 (Coolify UI)

<!-- AI-CONTEXT-END -->

Coolify is a self-hosted, open-source alternative to Vercel/Netlify/Heroku using Docker containers.

## Configuration

```bash
cp configs/coolify-config.json.txt configs/coolify-config.json
```

Multi-server config (`configs/coolify-config.json`):

```json
{
  "servers": {
    "coolify-main": {
      "name": "Main Coolify Server",
      "host": "coolify.yourdomain.com",
      "ip": "your-server-ip",
      "coolify_url": "https://coolify.yourdomain.com",
      "ssh_key": "~/.ssh/id_ed25519"
    },
    "coolify-staging": {
      "name": "Staging Coolify Server",
      "host": "staging-coolify.yourdomain.com",
      "ip": "staging-server-ip",
      "coolify_url": "https://staging-coolify.yourdomain.com",
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

## Usage

### Server Management

```bash
./.agents/scripts/coolify-helper.sh list
./.agents/scripts/coolify-helper.sh connect coolify-main
./.agents/scripts/coolify-helper.sh open coolify-main
./.agents/scripts/coolify-helper.sh status coolify-main
```

### Application Management

```bash
./.agents/scripts/coolify-helper.sh apps main_server
./.agents/scripts/coolify-helper.sh exec coolify-main 'docker ps'
./.agents/scripts/coolify-helper.sh exec coolify-main 'docker logs container-name'
./.agents/scripts/coolify-helper.sh exec coolify-main 'df -h'
```

### SSH Configuration

```bash
./.agents/scripts/coolify-helper.sh generate-ssh-configs
ssh coolify-main
```

## Security

### Firewall

```bash
./.agents/scripts/coolify-helper.sh exec coolify-main 'ufw allow 22/tcp'
./.agents/scripts/coolify-helper.sh exec coolify-main 'ufw allow 80/tcp'
./.agents/scripts/coolify-helper.sh exec coolify-main 'ufw allow 443/tcp'
./.agents/scripts/coolify-helper.sh exec coolify-main 'ufw allow 8000/tcp'
./.agents/scripts/coolify-helper.sh exec coolify-main 'ufw enable'
```

### SSH Keys

- Use Ed25519 keys; rotate regularly; restrict SSH access to specific IPs
- Store backup access credentials securely

## Troubleshooting

### Deployment Failures

```bash
./.agents/scripts/coolify-helper.sh exec coolify-main 'docker logs build-container'
./.agents/scripts/coolify-helper.sh exec coolify-main 'df -h'
./.agents/scripts/coolify-helper.sh exec coolify-main 'free -h'
```

### SSL Certificate Issues

```bash
nslookup yourdomain.com
./.agents/scripts/coolify-helper.sh exec coolify-main 'docker logs coolify'
./.agents/scripts/coolify-helper.sh exec coolify-main 'certbot renew'
```

### Application Not Accessible

```bash
./.agents/scripts/coolify-helper.sh exec coolify-main 'docker ps'
./.agents/scripts/coolify-helper.sh exec coolify-main 'docker logs app-container'
./.agents/scripts/coolify-helper.sh exec coolify-main 'netstat -tlnp'
```

## Performance

```bash
./.agents/scripts/coolify-helper.sh exec coolify-main 'docker stats'
./.agents/scripts/coolify-helper.sh exec coolify-main 'htop'
./.agents/scripts/coolify-helper.sh exec coolify-main 'iostat -x 1'
./.agents/scripts/coolify-helper.sh exec coolify-main 'docker exec postgres-container pg_stat_activity'
./.agents/scripts/coolify-helper.sh exec coolify-main 'docker exec postgres-container pg_dump dbname > backup.sql'
```

- Set CPU/memory limits per container; configure health checks; use Redis caching; CDN for static assets

## Docker & Container Management

```bash
# Container operations
./.agents/scripts/coolify-helper.sh exec coolify-main 'docker ps -a'
./.agents/scripts/coolify-helper.sh exec coolify-main 'docker logs -f container-name'
./.agents/scripts/coolify-helper.sh exec coolify-main 'docker exec -it container-name bash'
./.agents/scripts/coolify-helper.sh exec coolify-main 'docker stats container-name'

# Image cleanup
./.agents/scripts/coolify-helper.sh exec coolify-main 'docker images'
./.agents/scripts/coolify-helper.sh exec coolify-main 'docker image prune -a'
./.agents/scripts/coolify-helper.sh exec coolify-main 'docker volume prune'
```

## Backup & Recovery

- Source code: Git repositories
- Databases: `pg_dump` / automated Coolify backups
- Volumes: Docker volume snapshots
- Config: Coolify configuration exports
- Server: Cloud provider snapshots (Hetzner/DigitalOcean/AWS APIs)

## Best Practices

- **Workflow**: push to Git → Coolify auto-deploys → health check → rollback if needed
- **Environments**: separate dev/staging/prod with distinct databases and domains
- **Monitoring**: use built-in Coolify monitoring + centralized log collection
- **Backups**: verify restores regularly
