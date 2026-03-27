---
description: Cloudron self-hosted app platform
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
---

# Cloudron App Platform Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Self-hosted app platform (100+ apps), auto-updates/backups/SSL
- **Auth**: API token from Dashboard > Settings > API Access (9.1+: passkey/OIDC login)
- **Config**: `configs/cloudron-config.json`
- **Commands**: `cloudron-helper.sh [servers|connect|status|apps|install-app|update-app|restart-app|logs|backup-app|domains|add-domain|users|add-user] [server] [args]`
- **CLI ops**: `cloudron-server-ops-skill.md` (full CLI reference from upstream)
- **Packaging**: `cloudron-app-packaging.md` (native guide), `cloudron-app-packaging-skill.md` (upstream skill)
- **Publishing**: `cloudron-app-publishing-skill.md` (community packages via CloudronVersions.json)
- **API test**: `curl -H "Authorization: Bearer TOKEN" https://cloudron.domain.com/api/v1/cloudron/status`
- **SSH access**: `ssh root@cloudron.domain.com` for direct server diagnosis
- **Forum**: [forum.cloudron.io](https://forum.cloudron.io) for known issues and solutions
- **Docker**: `docker ps -a` (states), `docker logs <container>`, `docker exec -it <container> /bin/bash`
- **DB creds**: `docker inspect <container> | grep CLOUDRON_MYSQL` (redact secrets before sharing output)

<!-- AI-CONTEXT-END -->

## What's New in 9.1

Cloudron 9.1 (released to unstable 2026-03-01) introduces:

- **Custom app build and deploy**: `cloudron install` uploads package source and builds on-server. Source is backed up and rebuilt on restore.
- **Community packages**: Install third-party apps from a `CloudronVersions.json` URL via the dashboard. See `cloudron-app-publishing-skill.md`.
- **Passkey authentication**: FIDO2/WebAuthn passkey support. Tested with Bitwarden, YubiKey 5, Nitrokey, and native browser/OS support.
- **OIDC CLI login**: Browser-based OIDC login for CLI. Pre-obtained API tokens still work for CI/CD.
- **Addon upgrades**: MongoDB 8, Redis 8.4, Node.js 24.x
- **ACME ARI support**: RFC 9773 for certificate renewal information
- **Backup integrity verification UI** and improved progress reporting

**Source**: [forum.cloudron.io/topic/14976](https://forum.cloudron.io/topic/14976/what-s-coming-in-9-1)

## Configuration

```bash
cp configs/cloudron-config.json.txt configs/cloudron-config.json
```

```json
{
  "servers": {
    "production": {
      "hostname": "cloudron.yourdomain.com",
      "api_token": "YOUR_CLOUDRON_API_TOKEN_HERE"
    },
    "staging": {
      "hostname": "staging-cloudron.yourdomain.com",
      "api_token": "YOUR_STAGING_CLOUDRON_API_TOKEN_HERE"
    }
  }
}
```

API token: Dashboard > Settings > API Access > Generate.

## Usage Examples

```bash
# Server management
./.agents/scripts/cloudron-helper.sh servers
./.agents/scripts/cloudron-helper.sh status production
./.agents/scripts/cloudron-helper.sh apps production

# App management
./.agents/scripts/cloudron-helper.sh install-app production wordpress blog.yourdomain.com
./.agents/scripts/cloudron-helper.sh update-app production app-id
./.agents/scripts/cloudron-helper.sh restart-app production app-id
./.agents/scripts/cloudron-helper.sh logs production app-id
./.agents/scripts/cloudron-helper.sh backup-app production app-id

# Domain management
./.agents/scripts/cloudron-helper.sh domains production
./.agents/scripts/cloudron-helper.sh add-domain production newdomain.com
./.agents/scripts/cloudron-helper.sh ssl-status production newdomain.com

# User management
./.agents/scripts/cloudron-helper.sh users production
./.agents/scripts/cloudron-helper.sh add-user production newuser@domain.com
./.agents/scripts/cloudron-helper.sh update-user production user-id admin
```

## Troubleshooting

**Always check [forum.cloudron.io](https://forum.cloudron.io) first** — search error messages from app logs. Most post-update issues have forum threads with official workarounds.

### Post-Reboot / Post-Update Diagnostic Playbook

Follow this order — each step narrows the diagnosis.

**Step 1: Establish context**

```bash
ssh root@my.cloudron.domain.com
uptime                                                          # <10 min = apps still starting
last reboot | head -5
journalctl -b -1 --no-pager | grep -i -E 'cloudron.*update|cloudron-updater'
jq -r '.version // "not found"' /home/yellowtent/box/package.json
```

**Step 2: Assess system resources**

```bash
free -h && df -h / && uptime
```

**Step 3: Container state summary**

```bash
docker ps -a --format '{{.State}}' | sort | uniq -c | sort -rn
docker ps -a --filter 'status=exited' --format '{{.Names}}\t{{.Status}}' \
  | grep -v -E 'cleanup|archive|housekeeping|previewcleanup|jobs'
```

**Step 4: Read the box.log** (primary diagnostic)

```bash
tail -100 /home/yellowtent/platformdata/logs/box.log
systemctl status box.service
grep 'app health:' /home/yellowtent/platformdata/logs/box.log | tail -5
```

**Step 5: Monitor progress** (run every 60 seconds)

```bash
echo "=== $(date) ===" && \
docker ps -a --format '{{.State}}' | sort | uniq -c | sort -rn && \
tail -1 /home/yellowtent/platformdata/logs/box.log
```

### Cloudron Startup Architecture

Understanding the startup sequence prevents premature intervention:

1. **Infrastructure services** (2-3 min): `box.service` starts, then MySQL, PostgreSQL, MongoDB, mail, graphite, sftp, turn — sequentially.
2. **Redis sidecars** (3-5 min): Each app with a Redis addon gets its own container, started **one at a time** (~16 seconds each). Initial `ECONNREFUSED` on attempt 1 is normal.
3. **App containers** (2-5 min): Started with a concurrency limit (~15). `At concurrency limit, cannot drain anymore` and `N apptasks pending` are normal queuing messages.
4. **Health checks** (1-2 min): Apps need time to initialize. `unresponsive` until the HTTP endpoint responds.

**Expected total recovery time**: 8-15 minutes for 30+ apps. High load average (5-15) and "restarting"/"not responding" in the dashboard are normal during this window.

**When to intervene**: After 15 minutes if box.log shows the same Redis container failing repeatedly (>5 attempts) or container state counts aren't changing.

### Identifying Stuck vs Normal Startup

| Symptom | Normal Startup | Genuinely Stuck |
|---------|---------------|-----------------|
| `ECONNREFUSED` in box.log | Attempt 1-2 per Redis, then moves on | Same container >5 attempts, never moves to next |
| `At concurrency limit` | Pending count decreases over time | Pending count stays the same for >5 min |
| High load average | Decreasing over 5-10 min | Sustained >10 after 15 min |
| Exited containers | Count decreasing as apps start | Count not changing after 10 min |
| `created` state containers | Transitioning to `running` | Stuck in `created` for >10 min |

### Known Cloudron 9.x Post-Update Issues

**Redis not starting (9.1.3+)**: Containers fail with `Permission denied` writing PID file to `/run/redis`. One stuck Redis blocks the entire sequential startup chain. Forum: search "redis not starting 9.1".

**DB migration failures (8.x to 9.x upgrade)**: The `oidcClients` migration fails if any app's `cloudronManifest.json` has no `addons` object. Symptoms: `Cannot read properties of undefined (reading 'oidc')` or `Unknown column 'pending'/'completed' in 'field list'`. Fix: manually add empty addons objects to the MySQL `apps` table, then run `cloudron-support --apply-db-migrations`. Forum: search "Error accessing Dashboard after update from 8.x to 9.x".

**Docker network removal failure**: Infrastructure upgrade from 49.8.0 to 49.9.0 fails because Docker reports "network has active endpoints". All apps stuck in "Configuring". Fix: manually disconnect endpoints and remove the network, then restart box service. Forum: search "Apps stuck in Configuring due to failed infrastructure upgrade".

**Services stuck in "Starting services"**: After 9.0.11 update, infinite `grep -q avx /proc/cpuinfo` loops. Related to CPU feature detection on VMs without AVX support. Forum: search "Update 9.0.11 Broke Services".

**Health monitor stuck**: Apps work fine but dashboard shows permanent "Starting...". Fix: `systemctl restart box`. Forum: search "apps responsive but showing a permanent Starting status".

### Container State Reference

| State | Meaning | Action |
|-------|---------|--------|
| `Up` | Healthy | Normal operation |
| `Restarting` | Crash loop | Check logs, likely app/db issue |
| `Exited (0)` | Clean shutdown | Cloudron hasn't started it yet (normal post-reboot) |
| `Exited (1)` | Error exit | Check `docker logs <container>` for the error |
| `Exited (137)` | Killed (SIGKILL/OOM) | Check `dmesg \| grep -i oom` and memory limits |
| `Created` | Never started | Waiting in Cloudron's startup queue |

### Key Log Files

| Log/Service | Location | Purpose |
|-------------|----------|---------|
| Box service log | `/home/yellowtent/platformdata/logs/box.log` | Primary diagnostic |
| Box service status | `systemctl status box.service` | Is the Cloudron platform running? |
| App-specific logs | `docker logs <container_name>` | Individual app errors |
| System journal (previous boot) | `journalctl -b -1 --no-pager -n 50 -p warning` | Pre-reboot events |
| Cloudron troubleshoot | `cloudron-support --troubleshoot` | Built-in diagnostic checks |
| Cloudron version | `jq -r '.version // "not found"' /home/yellowtent/box/package.json` | Current version |

### Database Troubleshooting (MySQL)

```bash
# Find MySQL credentials from app container
docker inspect <app_container> | grep CLOUDRON_MYSQL
# Reveals: CLOUDRON_MYSQL_HOST, PORT, USERNAME, PASSWORD, DATABASE (hex string)

# Connect via the mysql container
docker exec -it mysql mysql -u<username> -p<password> <database>
```

> **Security note**: `docker inspect` reveals database credentials. Redact passwords before sharing output. The `-p$(cat ...)` pattern briefly exposes the password in the process list — prefer env var injection where possible (see `reference/secret-handling.md` §8.3).

**Charset/Collation Issues** (common after updates):

```sql
-- Check current charset
SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME
FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'your_db_hex';

-- Fix table charset (example for Vaultwarden SSO issue)
ALTER TABLE sso_nonce CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE sso_users CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
```

### App Recovery Mode

When an app won't start: Apps → Select App → Advanced → Enable Recovery Mode. App starts with minimal config, bypassing startup scripts. Use for database repairs, config fixes, manual migrations.

```bash
docker exec -it <app_container> /bin/bash
# Make fixes, then disable recovery mode via dashboard
```

### App Startup Failures (Post-Update)

1. Check container state: `docker ps -a | grep <app_subdomain>`
2. Review logs: `docker logs --tail 200 <container>`
3. Search forum: Copy error message to forum.cloudron.io search
4. Check database: Often charset/migration issues
5. Enable recovery mode if database fix needed
6. Apply fix (usually SQL commands from forum solution)
7. Restart app via dashboard or `docker restart <container>`

### App-Specific Troubleshooting

- **Vaultwarden**: `../../tools/credentials/vaultwarden.md`
- **WordPress**: `../../tools/wordpress/`

## Related Skills and Subagents

| Resource | Path | Purpose |
|----------|------|---------|
| App packaging (native) | `tools/deployment/cloudron-app-packaging.md` | Full packaging guide with aidevops helper scripts |
| App packaging (upstream) | `tools/deployment/cloudron-app-packaging-skill.md` | Official Cloudron skill with manifest/addon refs |
| App publishing | `tools/deployment/cloudron-app-publishing-skill.md` | CloudronVersions.json and community packages |
| Server ops | `tools/deployment/cloudron-server-ops-skill.md` | Full CLI reference for managing installed apps |
| Git reference | `tools/deployment/cloudron-git-reference.md` | Using git.cloudron.io for packaging patterns |
| Helper script | `scripts/cloudron-helper.sh` | Multi-server management via API |
| Package helper | `scripts/cloudron-package-helper.sh` | Local packaging development workflow |
