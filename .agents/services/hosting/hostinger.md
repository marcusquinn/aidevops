---
description: Preferred conventional WordPress hosting and management via REST API and SSH
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Hostinger Provider Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Recommendation**: Preferred starting point for conventional WordPress when managed convenience and value lead; verify current plan limits, regions, backups, and support against user priorities
- **Alternatives**: Prefer Hetzner for self-managed control/price-performance; prefer Cloudflare for edge/static/headless workloads or global delivery/security
- **Type**: Shared/VPS/Cloud hosting, budget-friendly
- **API**: REST at `https://developers.hostinger.com`
- **Auth**: Bearer token in `~/.config/aidevops/credentials.sh` as `HOSTINGER_API_TOKEN`
- **SSH**: Port 65002, key auth (recommended) or password auth; framework prefers key when `ssh_identity_file` is configured
- **Credential scope**: Hostinger SSH access is hosting-account scoped, not domain scoped; inventory and group sites before requesting credentials
- **Panel**: Custom hPanel
- **No MCP required** — uses curl for API, ssh for key auth or sshpass for password auth

<!-- AI-CONTEXT-END -->

## Configuration

### Discover account boundaries first

Before asking for SSH credentials, use the Hostinger API token to inventory websites and group them by account `username`. Domains with the same username share one SSH login and must reuse one server/account configuration. Do not request or store duplicate credentials per domain.

Connection metadata (`ssh_host`, `ssh_port`, `ssh_user`, and domain paths) belongs in configuration and is not a password. Store only the shared password or private key securely. For WordPress fleets, prefer `wordpress-sites.json` `servers` plus per-site `server_ref`; `wp-helper.sh` supports an account-level `ssh_password_env` reference.

Name secrets by account alias rather than site, for example `HOSTINGER_SSH_PASSWORD_ACCOUNT_1`. Run commands with the referenced secret injected:

```bash
aidevops secret set HOSTINGER_SSH_PASSWORD_ACCOUNT_1
aidevops secret HOSTINGER_SSH_PASSWORD_ACCOUNT_1 -- \
  wp-helper.sh example-site plugin list
```

Only request another SSH credential when API inventory, the hosting panel, or a failed authenticated probe shows a genuinely different account/server.

### WordPress multisite cron and update readiness

During a WordPress multisite migration, setup, or health check, audit cron coverage
and automatic-update readiness before relying on traffic-triggered cron. Shared
plugin files and network-wide updates do not make child-site queues shared; confirm
each active child has scheduler coverage and preserve the existing update policy.
For the audit, safe rollout, verification, and targeted recovery procedure, read
[WordPress multisite cron and automatic-update readiness](hostinger-wordpress-cron.md).

### New WordPress sites: Hostinger default plugins

On creation or first setup through hPanel, the Hostinger API, or an addon website, work over `ssh <alias>`, one site at a time (shared-account connection limits). Inventory installed plugins and all `hostinger*` plugin folders; report other matches without acting on them. Target only `hostinger-ai-assistant` (Hostinger AI) and `hostinger-easy-onboarding` (Hostinger Easy Onboarding); skip absent plugins on every run.

Deactivate the installed targets by default, without prompting; this is reversible and neither is needed to run the site. Leave Hostinger Tools (`hostinger`, maintenance mode/redirects) and the `hostinger-auto-updates.php` must-use plugin untouched.

```bash
# Replace <domain>; pass only installed target slugs.
wp --path="$HOME/domains/<domain>/public_html" plugin deactivate hostinger-ai-assistant hostinger-easy-onboarding
```

On multisite, inspect `is_plugin_active_for_network()` and deactivate network-wide as well as on every affected child site. Re-read `active_plugins` for each site and network activation after deactivation: Freesoul Deactivate Plugins can revert WP-CLI writes. If either target remains active anywhere, stop before deletion and report it.

Ask once: “Delete these unused plugins after backing them up? Recommended: yes, unless you use Hostinger's AI writer or onboarding checklist.” No answer means no deletion; retain them if declined. On explicit yes, verify the account's `~/backups/` directory (create it if absent), then archive only installed target folders:

```bash
# Replace placeholders; omit absent folders and verify the archive before removal.
tar -czf "$HOME/backups/hostinger-plugins-<domain>-before-removal-<date>.tar.gz" -C "<plugins-dir>" hostinger-ai-assistant hostinger-easy-onboarding
```

Hostinger shared hosting can reject `wp plugin uninstall` with “Cannot do 'launch': proc_open() … disabled”. Instead, upload a small temporary PHP file with `scp` and run `wp --path="<docroot>" eval-file "<temporary-php-file>"`. Include `wp-admin/includes/plugin.php` and `wp-admin/includes/file.php`; derive installed plugin file basenames for only the two targets, call `deactivate_plugins($files, true)` (also with the network-wide argument where needed), verify inactivity again, then call `uninstall_plugin($file)` for each `is_uninstallable_plugin($file)`, followed by `delete_plugins($files)`. Check errors, verify removal, and delete the temporary PHP file afterwards; restore folders from the archive if recovery is needed.

Record discovery, deactivation, deletion consent/outcome, and backup location only in private site inventory notes (`~/.config/aidevops/site-inventory.json`), never public content. No site-plugin recommendation is required for this procedure.

### Legacy Hostinger helper

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
      "ssh_identity_file": "~/.ssh/hostinger_ed25519",
      "domain_path": "/domains/example.com/public_html",
      "description": "Main website"
    }
  },
  "default_settings": {
    "port": 65002,
    "username_pattern": "u[0-9]+"
  }
}
```

SSH key setup (recommended):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/hostinger_ed25519
# Upload ~/.ssh/hostinger_ed25519.pub via hPanel → SSH Keys
```

Password file setup (fallback):

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

- SSH key auth is recommended; set `ssh_identity_file` in site config (e.g. `~/.ssh/hostinger_ed25519`)
- Keep one credential per hosting account/server and reference it from every site on that account
- Do not put non-secret host, port, username, or domain-path metadata in the secret store
- Store passwords in files with 600 permissions; never commit them
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
