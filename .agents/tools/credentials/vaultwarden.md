---
description: Vaultwarden self-hosted password management
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

# Vaultwarden (Self-hosted Bitwarden) Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Self-hosted password manager (Bitwarden API compatible)
- **CLI**: `npm install -g @bitwarden/cli` then `bw`
- **Auth**: `bw login email` → `export BW_SESSION=$(bw unlock --raw)`
- **Config**: `configs/vaultwarden-config.json` (copy from `configs/vaultwarden-config.json.txt`)
- **Commands**: `vaultwarden-helper.sh [instances|status|login|unlock|list|search|get|get-password|create|audit|start-mcp] [instance] [args]`
- **Session**: `BW_SESSION` env var required after unlock; `unset BW_SESSION && bw lock` when done
- **Server**: `vault.bitwarden.com` = cloud; any other domain = self-hosted (`bw config server <url>`)
- **MCP**: Port 3002 for AI assistant credential access
- **Backup**: `bw export --format json` (encrypt with GPG)

<!-- AI-CONTEXT-END -->

## Configuration

```json
{
  "instances": {
    "production": { "server_url": "https://vault.yourdomain.com" },
    "development": { "server_url": "https://dev-vault.yourdomain.com" }
  }
}
```

## Helper Commands

```bash
# Instance management
vaultwarden-helper.sh instances
vaultwarden-helper.sh status production
vaultwarden-helper.sh login production user@example.com
vaultwarden-helper.sh unlock

# Vault operations
vaultwarden-helper.sh list production
vaultwarden-helper.sh search production "github"
vaultwarden-helper.sh get production item-uuid
vaultwarden-helper.sh get-password production "GitHub Account"
vaultwarden-helper.sh get-username production "GitHub Account"

# Item management
vaultwarden-helper.sh create production "New Service" username password123 https://service.com
vaultwarden-helper.sh update production item-uuid password newpassword123
vaultwarden-helper.sh delete production item-uuid
vaultwarden-helper.sh generate 20 true

# Org / sync / export
vaultwarden-helper.sh org-list production org-uuid
vaultwarden-helper.sh sync production
vaultwarden-helper.sh export production json vault-backup.json

# Security / MCP
vaultwarden-helper.sh audit production
vaultwarden-helper.sh lock
vaultwarden-helper.sh start-mcp production 3002
vaultwarden-helper.sh test-mcp 3002
```

## MCP Integration

```json
{
  "bitwarden": {
    "command": "bitwarden-mcp-server",
    "args": ["--port", "3002"],
    "env": { "BW_SERVER": "https://vault.yourdomain.com" }
  }
}
```

## Backup

```bash
# Manual
vaultwarden-helper.sh export production json vault-backup-$(date +%Y%m%d).json
chmod 600 vault-backup-*.json
```

Automated backup (GPG-encrypted, 30-day retention):

```bash
#!/bin/bash
INSTANCE="production"
BACKUP_DIR="/secure/backups/vaultwarden"
DATE=$(date +%Y%m%d-%H%M%S)

vaultwarden-helper.sh export "$INSTANCE" json "$BACKUP_DIR/vault-$DATE.json"
gpg --cipher-algo AES256 --compress-algo 1 --s2k-mode 3 \
    --s2k-digest-algo SHA512 --s2k-count 65536 --symmetric \
    "$BACKUP_DIR/vault-$DATE.json"
rm "$BACKUP_DIR/vault-$DATE.json"
find "$BACKUP_DIR" -name "vault-*.json.gpg" -mtime +30 -delete
```

## Troubleshooting

```bash
curl -I https://vault.yourdomain.com          # connection check
bw config server https://vault.yourdomain.com  # set server
bw status                                      # auth state
bw logout && bw login user@example.com         # re-auth
bw sync --force                                # force sync
```
