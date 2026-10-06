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

### PHP runtime

Read-only observations from one managed-hosting account on **2026-10-05**, not universal plan defaults: LiteSpeed Enterprise with persistent `lsphp` workers (some alive for over a day), `LSPHP_ProcessGroup=on`, `LSAPI_CHILDREN=180`, `LSAPI_MAX_IDLE_CHILDREN=90`, `LSAPI_MAX_IDLE=600`, and `LSAPI_MAX_PROCESS_TIME=300`; CloudLinux LVE cgroup membership. Web SAPI and effective account limits still require per-site verification.

The observed OPcache configuration was 1024M memory, 130,987 maximum accelerated files, and 64M interned strings; JIT was off and preload unset. PHP 8.5 **CLI** reported `memory_limit=12288M`: this is not evidence of the web limit or available account RAM. Verify web settings in the application's status page and hPanel → PHP Configuration. Worker counts and OPcache size are host-controlled on managed hosting; do not replace working LSAPI with FPM or attempt pool edits.

Supported per-site overrides can use `.htaccess` `php_value` inside `<IfModule lsapi_module>`; confirm the directive is allowed before proposing a change. Really Simple Security was observed writing `auto_prepend_file` into both that block and `.user.ini`; a migrated site retained a stale `.user.ini` path from its previous account. Inspect only authorized site files and preserve security-plugin ownership when proposing a backed-up repair.

Dated uploads directories returned 403 in this observation. Verify directory-listing protection per site rather than assuming it applies to every account. For the read-only baseline, worker/memory sizing, OPcache assessment, host boundaries, and safe directory-listing remediation, read `tools/runtime/php-server-admin.md`.

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

### Retiring a website

`DELETE /api/hosting/v1/websites/{domain}` permanently removes a main or addon website with its files, databases and configuration; the plan stays. It rejects parked domains and subdomains, and it runs asynchronously (returns "Request accepted").

1. **Confirm the target**: `GET /api/hosting/v1/websites?domain=<domain>` must return `vhost_type` `main` or `addon`. Check that no other site's `wp-config.php` uses its database.
2. **Back up** files (`tar` of `~/domains/<domain>`) and the database (see "Database backups without WP-CLI"), then verify the archive file count and dump table count.
3. **Detach managers first**: remove the site from MainWP (`tools/wordpress/mainwp.md` "Removing a child site over SSH") while the child plugin can still respond.
4. **Delete**, wait about a minute, then verify: the website list returns no entry, `~/domains/<domain>` is gone, and `GET /api/hosting/v1/accounts/{username}/databases` no longer lists its database.
5. **Clean up leftovers the delete does not touch**: account cron jobs pointing at the old docroot (`GET`/`DELETE /api/hosting/v1/accounts/{username}/cron-jobs[/{uid}]`) and external DNS records (for example Cloudflare).

Take `{username}` from the website list response inside the same command; tool output may redact it, and a copied placeholder silently produces an empty response.

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

### WP-CLI limits on shared hosting

Observed with WP-CLI 2.12.0 and PHP 8.x: Hostinger shared hosting disables PHP CLI `proc_open()`/`proc_close()`. `wp plugin delete` calls `WP_CLI::launch()` to remove files through a subprocess, so it (and other commands that shell out) can fail with:

```text
Error: Cannot do 'launch': The PHP functions `proc_open()` and/or `proc_close()` are disabled. Please check your PHP ini directive `disable_functions` or suhosin settings.
```

`wp plugin deactivate` and `wp plugin install <zip> --force` can still work. For an authorized removal **keeping saved data**, back up first, verify the exact plugin folder and all plugin file basenames, and use WordPress's filesystem API without a subprocess. Replace `SLUG/SLUG.php` with the installed basename (check every plugin in the folder); never substitute an unchecked path. On multisite, verify inactivity on every child site and network-wide before deleting shared files; the guard below checks only the current site and network.

```bash
WP="$HOME/domains/<domain>/public_html"
wp --path="$WP" eval 'require_once ABSPATH . "wp-admin/includes/plugin.php";
require_once ABSPATH . "wp-admin/includes/file.php";
if (is_plugin_active("SLUG/SLUG.php") || is_plugin_active_for_network("SLUG/SLUG.php")) {
    WP_CLI::error("active, skipped");
}
if (!WP_Filesystem()) { WP_CLI::error("Filesystem initialization failed"); }
global $wp_filesystem;
if (!$wp_filesystem->delete(WP_PLUGIN_DIR . "/SLUG", true)) { WP_CLI::error("Deletion failed"); }
WP_CLI::success("Files deleted; uninstall routine not run");'
```

This bypasses uninstall hooks, preserving saved data rather than asking the plugin to erase it. When uninstall/data cleanup is explicitly wanted, use `delete_plugins(array("SLUG/SLUG.php"))` inside `wp eval` with the same includes and inactivity checks instead of `$wp_filesystem->delete(...)`. It runs registered uninstall routines, like the Plugins screen's Delete; inspect its return value with `is_wp_error()` and treat anything other than `true` as failure. Verify folder removal and site health afterwards. Plain `rm -rf` over SSH also works but bypasses WordPress and these guards; do not use it as an automatic fallback.

- **Account paths and logs**: One account SSH login covers its sites at `~/domains/<domain>/public_html`; inspect each site's `error_log` there.
- **Release ZIP updates**: `scp` the ZIP once to the account, run `wp --path="$WP" plugin install ~/plugin.zip --force` per intended site, verify the update, then remove the uploaded ZIP.
- **PHAR autoloader warnings**: `include(...vendor/composer/../psr/container/...): Failed to open stream` can be WP-CLI autoloader noise with plugins shipping prefixed vendors (observed with Kadence Pro 1.2.5), not proof of a broken install. Check the plugin's `vendor/vendor-prefixed/` files and the site's `error_log`, and verify site behavior before attempting a repair.
- **SQL queries**: `wp db query` fails with `Cannot do 'Process::run'`; use `global $wpdb;` inside `wp eval` instead. `wp db size` still works.

### Database backups without WP-CLI

`wp db export` also fails with `Cannot do 'Process::run'`. Call `mysqldump` directly with the site's own credentials, passed through the environment so the password never appears in output or the process list:

```bash
cd "$HOME/domains/<domain>/public_html"
export MYSQL_PWD="$(wp eval 'echo DB_PASSWORD;')"
mysqldump -h "$(wp eval 'echo DB_HOST;')" -u "$(wp eval 'echo DB_USER;')" \
  --single-transaction --no-tablespaces "$(wp eval 'echo DB_NAME;')" |
  gzip -c >"$HOME/backups/<domain>-db-<date>.sql.gz"
unset MYSQL_PWD
chmod 600 "$HOME/backups/<domain>-db-<date>.sql.gz"
zcat "$HOME/backups/<domain>-db-<date>.sql.gz" | grep -c 'CREATE TABLE'   # verify
```

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
