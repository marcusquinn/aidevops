---
description: Hostinger hosting management via REST API and SSH
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
---

# Hostinger Provider Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Shared/VPS/Cloud hosting, budget-friendly
- **API**: REST at `https://developers.hostinger.com`
- **Auth**: Bearer token in `~/.config/aidevops/credentials.sh` as `HOSTINGER_API_TOKEN`
- **SSH**: Port 65002, password auth (no SSH keys on shared)
- **Panel**: Custom hPanel
- **No MCP required** — uses curl for API, sshpass for SSH

<!-- AI-CONTEXT-END -->

## Configuration

Copy template and edit with server details:

```bash
cp configs/hostinger-config.json.txt configs/hostinger-config.json
```

Config structure:

```json
{
  "sites": {
    "example.com": {
      "server": "server-hostname-or-ip",
      "port": 65002,
      "username": "u123456789",
      "password_file": "~/.ssh/hostinger_password",
      "domain_path": "/domains/example.com/public_html",
      "description": "Main website"
    }
  },
  "default_settings": {
    "port": 65002,
    "username_pattern": "u[0-9]+",
    "password_authentication": true,
    "ssh_keys_supported": false
  }
}
```

Password file setup:

```bash
echo 'your-hostinger-password' > ~/.ssh/hostinger_password
chmod 600 ~/.ssh/hostinger_password
brew install sshpass   # macOS
sudo apt-get install sshpass  # Linux
```

## Commands

```bash
# Site management
./.agents/scripts/hostinger-helper.sh list
./.agents/scripts/hostinger-helper.sh connect example.com
./.agents/scripts/hostinger-helper.sh exec example.com 'ls -la'

# File transfer
./.agents/scripts/hostinger-helper.sh upload example.com ./dist/ /domains/example.com/public_html/
./.agents/scripts/hostinger-helper.sh download example.com /domains/example.com/public_html/ ./backup/

# Database
./.agents/scripts/hostinger-helper.sh exec example.com 'mysqldump -u username -p database_name > backup.sql'
```

## Security

- Store passwords in files with 600 permissions; never commit them
- SSH keys not supported on shared hosting — password auth only
- Port 65002 (non-standard); be aware of concurrent connection limits

Set web file permissions:

```bash
./.agents/scripts/hostinger-helper.sh exec example.com 'chmod 644 /domains/example.com/public_html/*.html'
./.agents/scripts/hostinger-helper.sh exec example.com 'chmod 755 /domains/example.com/public_html/scripts/'
```

## Troubleshooting

**Connection refused**: Verify SSH is enabled on your plan, check hostname and port 65002, confirm password.

**Permission denied**: Username format is `u` followed by numbers (e.g. `u123456789`). Check password file has 600 perms and sshpass is installed.

**File upload issues**:

```bash
./.agents/scripts/hostinger-helper.sh exec example.com 'ls -la /domains/example.com/'
./.agents/scripts/hostinger-helper.sh exec example.com 'df -h'
```

## Deployment

```bash
# Build and deploy
npm run build
./.agents/scripts/hostinger-helper.sh upload example.com ./dist/ /domains/example.com/public_html/

# Verify
./.agents/scripts/hostinger-helper.sh exec example.com 'ls -la /domains/example.com/public_html/'
```

Backup before major changes:

```bash
DATE=$(date +%Y%m%d_%H%M%S)
./.agents/scripts/hostinger-helper.sh download example.com /domains/example.com/public_html/ ./backups/example.com_$DATE/
```
