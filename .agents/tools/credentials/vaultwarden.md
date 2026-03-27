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

# Vaultwarden (Self-hosted Bitwarden) Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Self-hosted password manager (Bitwarden API compatible)
- **CLI**: `npm install -g @bitwarden/cli` then `bw`
- **Auth**: `bw login email` then `export BW_SESSION=$(bw unlock --raw)`
- **Config**: `configs/vaultwarden-config.json` (template: `configs/vaultwarden-config.json.txt`)
- **Helper**: `vaultwarden-helper.sh [command] [instance] [args]`
- **Session**: `BW_SESSION` env var required after unlock
- **Lock**: `bw lock` and `unset BW_SESSION` when done
- **MCP**: Port 3002 for AI assistant credential access
- **Backup**: `bw export --format json` (encrypt with GPG)

<!-- AI-CONTEXT-END -->

## Service Detection

The `bw` CLI works for both Bitwarden cloud and Vaultwarden. Detect by server URL:

```bash
bw config server
# Default (cloud): https://vault.bitwarden.com
# Self-hosted: https://vault.yourdomain.com
```

Configure for self-hosted: `bw config server https://vault.yourdomain.com`

All premium features (TOTP, attachments, emergency access) are unlocked on Vaultwarden without subscription. API rate limits are configurable or absent.

## Configuration

```bash
# Copy template and edit with your instance details
cp configs/vaultwarden-config.json.txt configs/vaultwarden-config.json
```

The config supports multiple instances (production, development, personal) with per-instance server URLs, organizations, and user counts. See the template for the full schema including MCP server, backup, monitoring, and security policy settings.

## Helper Commands

All commands use the pattern: `vaultwarden-helper.sh <command> [instance] [args]`

| Command | Description | Example |
|---------|-------------|---------|
| `instances` | List configured instances | `vaultwarden-helper.sh instances` |
| `status` | Vault status | `vaultwarden-helper.sh status production` |
| `login` | Login to vault | `vaultwarden-helper.sh login production user@example.com` |
| `unlock` | Unlock vault (after login) | `vaultwarden-helper.sh unlock` |
| `lock` | Lock vault | `vaultwarden-helper.sh lock` |
| `list` | List all vault items | `vaultwarden-helper.sh list production` |
| `search` | Search vault items | `vaultwarden-helper.sh search production "github"` |
| `get` | Get specific item | `vaultwarden-helper.sh get production item-uuid` |
| `get-password` | Get password for item | `vaultwarden-helper.sh get-password production "GitHub Account"` |
| `get-username` | Get username for item | `vaultwarden-helper.sh get-username production "GitHub Account"` |
| `create` | Create new item | `vaultwarden-helper.sh create production "Service" user pass123 https://url` |
| `update` | Update item field | `vaultwarden-helper.sh update production item-uuid password newpass` |
| `delete` | Delete item | `vaultwarden-helper.sh delete production item-uuid` |
| `generate` | Generate password | `vaultwarden-helper.sh generate 20 true` |
| `sync` | Sync vault with server | `vaultwarden-helper.sh sync production` |
| `export` | Export vault | `vaultwarden-helper.sh export production json backup.json` |
| `org-list` | List org vault items | `vaultwarden-helper.sh org-list production org-uuid` |
| `audit` | Audit vault security | `vaultwarden-helper.sh audit production` |
| `start-mcp` | Start MCP server | `vaultwarden-helper.sh start-mcp production 3002` |
| `test-mcp` | Test MCP connection | `vaultwarden-helper.sh test-mcp 3002` |

## Session Management

```bash
# Login and unlock
bw login user@example.com
export BW_SESSION=$(bw unlock --raw)

# Use vault...

# Lock and clear session when done
bw lock
unset BW_SESSION
```

**Security rules**: Always lock the vault and unset `BW_SESSION` when finished. Run `vaultwarden-helper.sh audit production` periodically to detect weak or reused passwords.

## MCP Integration

```bash
# Start MCP server for AI assistant access
vaultwarden-helper.sh start-mcp production 3002
vaultwarden-helper.sh test-mcp 3002
```

MCP server config for AI assistants:

```json
{
  "bitwarden": {
    "command": "bitwarden-mcp-server",
    "args": ["--port", "3002"],
    "env": {
      "BW_SERVER": "https://vault.yourdomain.com"
    }
  }
}
```

Enables: credential retrieval, password generation, vault auditing, item management, and organization vault access.

## Troubleshooting

**Connection issues:**

```bash
curl -I https://vault.yourdomain.com    # Test connectivity
bw config server https://vault.yourdomain.com  # Verify/set server URL
```

**Authentication issues:**

```bash
bw status          # Check login/lock state
bw logout          # Reset if stuck
bw login user@example.com
bw unlock
```

**Sync issues:**

```bash
bw sync --force    # Force sync with server
# If persistent: bw logout → bw login (clears local cache)
```

## Backup & Recovery

```bash
# Manual backup
vaultwarden-helper.sh export production json vault-backup-$(date +%Y%m%d).json
chmod 600 vault-backup-*.json
```

**Automated backup script:**

```bash
#!/bin/bash
INSTANCE="production"
BACKUP_DIR="/secure/backups/vaultwarden"
DATE=$(date +%Y%m%d-%H%M%S)

# Export and encrypt
vaultwarden-helper.sh export $INSTANCE json "$BACKUP_DIR/vault-$DATE.json"
gpg --cipher-algo AES256 --compress-algo 1 --s2k-mode 3 \
    --s2k-digest-algo SHA512 --s2k-count 65536 --symmetric \
    "$BACKUP_DIR/vault-$DATE.json"
rm "$BACKUP_DIR/vault-$DATE.json"

# Retain 30 days
find "$BACKUP_DIR" -name "vault-*.json.gpg" -mtime +30 -delete
```
