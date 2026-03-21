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

Cloudron is a complete solution for running apps on your server, providing easy app installation, automatic updates, backups, and domain management.

## What's New in 9.1

Cloudron 9.1 (released to unstable 2026-03-01) introduces major features:

- **Custom app build and deploy**: `cloudron install` uploads package source and builds on-server. Source is backed up and rebuilt on restore. CLI-driven workflow for developers building custom apps or patching existing packages.
- **Community packages**: Install third-party apps from a `CloudronVersions.json` URL via the dashboard. Cloudron tracks the URL and auto-checks for updates. See `cloudron-app-publishing-skill.md`.
- **Passkey authentication**: FIDO2/WebAuthn passkey support for Cloudron login. Tested with Bitwarden, YubiKey 5, Nitrokey, and native browser/OS support.
- **OIDC CLI login**: CLI uses browser-based OIDC login to support passkeys. Pre-obtained API tokens still work for CI/CD pipelines.
- **Addon upgrades**: MongoDB 8, Redis 8.4, Node.js 24.x
- **ACME ARI support**: RFC 9773 for certificate renewal information
- **Backup integrity verification UI**: Verify backup integrity from the dashboard
- **Improved progress reporting**: Percentage complete and elapsed/estimated time for backups and installations
- **Better event log UI**: Separate notifications view

**Source**: [forum.cloudron.io/topic/14976](https://forum.cloudron.io/topic/14976/what-s-coming-in-9-1)

## Provider Overview

### **Cloudron Characteristics:**

- **Service Type**: Self-hosted app platform and server management
- **App Ecosystem**: 100+ pre-configured apps + community packages (9.1+)
- **Management**: Web-based dashboard for complete server management
- **Automation**: Automatic updates, backups, and SSL certificates
- **Multi-tenancy**: Support for multiple users and domains
- **API Support**: REST API for automation and integration
- **Security**: Built-in firewall, automatic security updates, passkey auth (9.1+)

### **Best Use Cases:**

- **Small to medium businesses** needing multiple web applications
- **Self-hosted alternatives** to SaaS applications
- **Development teams** needing staging and production environments
- **Organizations** requiring data sovereignty and privacy
- **Rapid application deployment** without complex configuration
- **Centralized management** of multiple applications and domains

## 🔧 **Configuration**

### **Setup Configuration:**

```bash
# Copy template
cp configs/cloudron-config.json.txt configs/cloudron-config.json

# Edit with your actual Cloudron server details
```

### **Configuration Structure:**

```json
{
  "servers": {
    "production": {
      "hostname": "cloudron.yourdomain.com",
      "ip": "192.168.1.100",
      "api_token": "YOUR_CLOUDRON_API_TOKEN_HERE",
      "description": "Production Cloudron server",
      "version": "7.5.0",
      "apps_count": 15
    },
    "staging": {
      "hostname": "staging-cloudron.yourdomain.com",
      "ip": "192.168.1.101",
      "api_token": "YOUR_STAGING_CLOUDRON_API_TOKEN_HERE",
      "description": "Staging Cloudron server",
      "version": "7.5.0",
      "apps_count": 5
    }
  }
}
```

### **API Token Setup:**

1. **Login to Cloudron Dashboard**
2. **Navigate to Settings** → API Access
3. **Generate API Token** with required permissions
4. **Copy token** to your configuration file
5. **Test access** with the helper script

## 🚀 **Usage Examples**

### **Basic Commands:**

```bash
# List all Cloudron servers
./.agents/scripts/cloudron-helper.sh servers

# Connect to Cloudron server
./.agents/scripts/cloudron-helper.sh connect production

# Get server status
./.agents/scripts/cloudron-helper.sh status production

# List installed apps
./.agents/scripts/cloudron-helper.sh apps production
```

### **App Management:**

```bash
# Install new app
./.agents/scripts/cloudron-helper.sh install-app production wordpress blog.yourdomain.com

# Install Matrix Synapse (for Matrix bot integration)
./.agents/scripts/cloudron-helper.sh install-app production matrix synapse.yourdomain.com
# See services/communications/matrix-bot.md for bot setup after Synapse installation

# Update app
./.agents/scripts/cloudron-helper.sh update-app production app-id

# Restart app
./.agents/scripts/cloudron-helper.sh restart-app production app-id

# Get app logs
./.agents/scripts/cloudron-helper.sh logs production app-id

# Backup app
./.agents/scripts/cloudron-helper.sh backup-app production app-id
```

### **Domain Management:**

```bash
# List domains
./.agents/scripts/cloudron-helper.sh domains production

# Add domain
./.agents/scripts/cloudron-helper.sh add-domain production newdomain.com

# Configure DNS
./.agents/scripts/cloudron-helper.sh configure-dns production newdomain.com

# Get SSL certificate status
./.agents/scripts/cloudron-helper.sh ssl-status production newdomain.com
```

### **User Management:**

```bash
# List users
./.agents/scripts/cloudron-helper.sh users production

# Add user
./.agents/scripts/cloudron-helper.sh add-user production newuser@domain.com

# Update user permissions
./.agents/scripts/cloudron-helper.sh update-user production user-id admin

# Reset user password
./.agents/scripts/cloudron-helper.sh reset-password production user-id
```

## 🛡️ **Security Best Practices**

### **Server Security:**

- **Regular updates**: Keep Cloudron platform updated
- **Firewall configuration**: Use Cloudron's built-in firewall
- **SSL certificates**: Ensure all apps have valid SSL certificates
- **Access control**: Implement proper user access controls
- **Backup encryption**: Enable backup encryption

### **API Security:**

- **Token rotation**: Rotate API tokens regularly
- **Minimal permissions**: Use tokens with minimal required permissions
- **Secure storage**: Store API tokens securely
- **Access monitoring**: Monitor API access and usage
- **HTTPS only**: Always use HTTPS for API access

### **App Security:**

```bash
# Check app security status
./.agents/scripts/cloudron-helper.sh security-status production

# Update all apps
./.agents/scripts/cloudron-helper.sh update-all-apps production

# Check SSL certificates
./.agents/scripts/cloudron-helper.sh ssl-check production

# Review user access
./.agents/scripts/cloudron-helper.sh audit-users production
```

## Troubleshooting

### Troubleshooting Resources

**Cloudron Forum**: Always check [forum.cloudron.io](https://forum.cloudron.io) for known issues:

- Search for error messages from app logs
- Check app-specific categories for recent issues
- Look for official workarounds from Cloudron staff
- Common post-update issues often have forum threads with solutions

### Post-Reboot / Post-Update Diagnostic Playbook

When apps show "restarting" or "not responding" after a reboot or Cloudron update, follow this systematic triage. The order matters — each step narrows the diagnosis.

**Step 1: Establish context** — Was this a reboot, a Cloudron update, or both?

```bash
ssh root@my.cloudron.domain.com

# How long has the server been up? If <10 min, apps may still be starting normally.
uptime

# Check reboot history — was this a manual reboot or automatic?
last reboot | head -5

# Check if Cloudron updated before the reboot
journalctl -b -1 --no-pager | grep -i -E 'cloudron.*update|cloudron-updater'

# Get the current Cloudron version
jq '.version' /home/yellowtent/box/package.json
```

**Step 2: Assess system resources** — Rule out OOM, disk full, or CPU saturation.

```bash
# Memory (is there enough for all apps to start?)
free -h

# Disk (Cloudron needs space for Docker images, logs, backups)
df -h /

# Load average (high is expected during startup — 5-15 is normal post-reboot)
uptime
```

**Step 3: Container state summary** — Get the big picture before diving into specifics.

```bash
# Count containers by state
docker ps -a --format '{{.State}}' | sort | uniq -c | sort -rn

# List non-running containers (exclude helper/cleanup containers)
docker ps -a --filter 'status=exited' --format '{{.Names}}\t{{.Status}}' \
  | grep -v -E 'cleanup|archive|housekeeping|previewcleanup|jobs'
```

**Step 4: Read the box.log** — This is the primary diagnostic log. It shows exactly what Cloudron is doing.

```bash
# Last 100 lines of the box service log
tail -100 /home/yellowtent/platformdata/logs/box.log

# Check the box service status
systemctl status box.service
```

**Step 5: Check the health monitor** — Shows how many apps Cloudron considers healthy.

```bash
# Look for the health summary lines
grep 'app health:' /home/yellowtent/platformdata/logs/box.log | tail -5
```

**Step 6: Monitor progress** — If apps are still starting, check again after 2-3 minutes.

```bash
# Quick progress check (run this every 60 seconds)
echo "=== $(date) ===" && \
docker ps -a --format '{{.State}}' | sort | uniq -c | sort -rn && \
tail -1 /home/yellowtent/platformdata/logs/box.log
```

### Cloudron Startup Architecture (Why It Takes Time)

Understanding the startup sequence prevents premature intervention:

1. **Infrastructure services start first** (2-3 min): `box.service` starts, then MySQL, PostgreSQL, MongoDB, mail, graphite, sftp, turn — sequentially.
2. **Redis sidecars start sequentially** (3-5 min for many apps): Each app with a Redis addon gets its own Redis container. Cloudron starts these **one at a time**, ~16 seconds each. A server with 15+ Redis instances takes 4-5 minutes just for this phase. Each Redis gets an initial `ECONNREFUSED` on attempt 1 — this is normal, not an error.
3. **App containers start with concurrency limit** (2-5 min): After Redis is up, Cloudron starts app containers with a concurrency limit (typically 15). The box.log shows `At concurrency limit, cannot drain anymore` and `N apptasks pending` — this is normal queuing, not a stuck state.
4. **Health checks run after containers start** (1-2 min): Apps need time to initialize internally. The health monitor reports `unresponsive` until the app's HTTP endpoint responds.

**Expected total recovery time**: 8-15 minutes for a server with 30+ apps. During this time, load average will be high (5-15) and the dashboard will show apps as "restarting" or "not responding". This is normal.

**When to intervene**: If after 15 minutes the box.log shows the same Redis container failing repeatedly (>5 attempts), or the container state counts aren't changing, something is genuinely stuck.

### Identifying Stuck vs Normal Startup

| Symptom | Normal Startup | Genuinely Stuck |
|---------|---------------|-----------------|
| `ECONNREFUSED` in box.log | Attempt 1-2 per Redis, then moves on | Same container >5 attempts, never moves to next |
| `At concurrency limit` | Pending count decreases over time | Pending count stays the same for >5 min |
| High load average | Decreasing over 5-10 min | Sustained >10 after 15 min |
| Exited containers | Count decreasing as apps start | Count not changing after 10 min |
| `created` state containers | Transitioning to `running` | Stuck in `created` for >10 min |

### Known Cloudron 9.x Post-Update Issues (from forum)

These are recurring patterns reported on [forum.cloudron.io](https://forum.cloudron.io) for Cloudron 9.x. When diagnosing, check if the symptoms match:

**Redis not starting (9.1.3+)**: Redis containers fail with `Permission denied` writing PID file to `/run/redis`. One stuck Redis blocks the entire sequential startup chain. Forum: search "redis not starting 9.1".

**DB migration failures (8.x to 9.x upgrade)**: The `oidcClients` migration fails if any app's `cloudronManifest.json` has no `addons` object (declared optional in docs but required by migration code). Symptoms: box.log shows `Cannot read properties of undefined (reading 'oidc')` or `Unknown column 'pending'/'completed' in 'field list'`. Fix: manually add empty addons objects to the MySQL `apps` table, then run `cloudron-support --apply-db-migrations`. Forum: search "Error accessing Dashboard after update from 8.x to 9.x".

**Docker network removal failure**: Infrastructure upgrade from 49.8.0 to 49.9.0 fails because Docker reports "network has active endpoints" when trying to remove the `cloudron` network. All apps stuck in "Configuring" / "Removing containers for upgrade". Fix: manually disconnect endpoints and remove the network, then restart box service. Forum: search "Apps stuck in Configuring due to failed infrastructure upgrade".

**Services stuck in "Starting services"**: After 9.0.11 update, services (graphite, mongodb, mysql, postgresql, sftp) never finish starting. Box.log shows infinite `grep -q avx /proc/cpuinfo` loops. Related to CPU feature detection on VMs without AVX support. Forum: search "Update 9.0.11 Broke Services".

**Health monitor stuck**: Apps work fine but dashboard shows permanent "Starting..." status. The health monitor gets stuck when one app lacks health checks, causing cascading health check failures for subsequently updated apps. Fix: `systemctl restart box`. Forum: search "apps responsive but showing a permanent Starting status".

### SSH Diagnostic Access

For deep troubleshooting, SSH directly into the Cloudron server:

```bash
# SSH into Cloudron server (use hostname from config)
ssh root@my.cloudron.domain.com

# Check all container states
docker ps -a

# Look for containers in "Restarting" state (indicates problems)
docker ps -a --filter "status=restarting"

# View container logs (last 100 lines)
docker logs --tail 100 <container_name>

# Follow logs in real-time
docker logs -f <container_name>

# Inspect container for environment variables and config
docker inspect <container_name>

# Execute commands inside a running container
docker exec -it <container_name> /bin/bash
```

### Container State Diagnosis

| State | Meaning | Action |
|-------|---------|--------|
| `Up` | Healthy | Normal operation |
| `Restarting` | Crash loop | Check logs, likely app/db issue |
| `Exited (0)` | Clean shutdown | Cloudron hasn't started it yet (normal post-reboot) |
| `Exited (1)` | Error exit | Check `docker logs <container>` for the error |
| `Exited (137)` | Killed (SIGKILL/OOM) | Check `dmesg | grep -i oom` and memory limits |
| `Created` | Never started | Waiting in Cloudron's startup queue |

### Key Log Files and Services

| Log/Service | Location | Purpose |
|-------------|----------|---------|
| Box service log | `/home/yellowtent/platformdata/logs/box.log` | Primary diagnostic — shows all startup, health, and error activity |
| Box service status | `systemctl status box.service` | Is the Cloudron platform itself running? |
| App-specific logs | `docker logs <container_name>` | Individual app startup/runtime errors |
| System journal (previous boot) | `journalctl -b -1 --no-pager -n 50 -p warning` | What happened before the reboot |
| Cloudron troubleshoot | `cloudron-support --troubleshoot` | Built-in diagnostic checks (DNS, certs, services, migrations) |
| Cloudron version | `jq '.version' /home/yellowtent/box/package.json` | Current Cloudron version |

### **Database Troubleshooting (MySQL)**

Cloudron apps use MySQL with randomly-generated database names. To troubleshoot:

```bash
# Find MySQL credentials from app container
docker inspect <app_container> | grep CLOUDRON_MYSQL

# This reveals:
# - CLOUDRON_MYSQL_HOST (usually "mysql")
# - CLOUDRON_MYSQL_PORT (usually 3306)
# - CLOUDRON_MYSQL_USERNAME
# - CLOUDRON_MYSQL_PASSWORD
# - CLOUDRON_MYSQL_DATABASE (hex string like "9ce6a923b53c880e")

# Connect to MySQL via the mysql container
docker exec -it mysql mysql -u<username> -p<password> <database>

# Or use root access (note: -p flag exposes password in process list briefly)
docker exec -it mysql mysql -uroot -p"$(cat /home/yellowtent/platformdata/mysql/root_password)"
```

> **Security note**: The `docker inspect` command above reveals database credentials. Redact passwords before pasting output into forum posts, tickets, or chat. The `-p$(cat ...)` pattern briefly exposes the password in the process list while the command runs. Prefer passing credentials via environment variables instead of command arguments where possible (see `prompts/build.txt` section 8.2).

#### **Common Database Fixes**

**Charset/Collation Issues** (common after updates):

```sql
-- Check current charset
SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME
FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'your_db_hex';

-- Fix table charset (example for Vaultwarden SSO issue)
ALTER TABLE sso_nonce CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER TABLE sso_users CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Check all tables in database
SELECT TABLE_NAME, TABLE_COLLATION
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'your_db_hex';
```

**Database Migration Errors**:

- Check forum for app-specific migration issues
- Often caused by charset mismatches after Cloudron/MySQL updates
- Solution usually involves ALTER TABLE commands before restarting app

### **App Recovery Mode**

When an app won't start, use Cloudron's recovery mode:

1. **Via Dashboard**: Apps → Select App → Advanced → Enable Recovery Mode
2. **Effect**: App starts with minimal config, bypasses startup scripts
3. **Use for**: Database repairs, config fixes, manual migrations

```bash
# After enabling recovery mode, access app container
docker exec -it <app_container> /bin/bash

# Make fixes, then disable recovery mode via dashboard
```

### **Common Issues:**

#### **API Connection Issues:**

```bash
# Test API connectivity
curl -H "Authorization: Bearer YOUR_TOKEN" https://cloudron.yourdomain.com/api/v1/cloudron/status

# Check server accessibility
ping cloudron.yourdomain.com

# Verify SSL certificate
openssl s_client -connect cloudron.yourdomain.com:443
```

#### **App Installation Issues:**

```bash
# Check available disk space
./.agents/scripts/cloudron-helper.sh exec production 'df -h'

# Check system resources
./.agents/scripts/cloudron-helper.sh exec production 'free -h'

# Review installation logs
./.agents/scripts/cloudron-helper.sh logs production app-id
```

#### **App Startup Failures (Post-Update)**

When apps fail after updates (common pattern):

1. **Check container state**: `docker ps -a | grep <app_subdomain>`
2. **Review logs**: `docker logs --tail 200 <container>`
3. **Search forum**: Copy error message to forum.cloudron.io search
4. **Check database**: Often charset/migration issues
5. **Enable recovery mode**: If database fix needed
6. **Apply fix**: Usually SQL commands from forum solution
7. **Restart app**: Via dashboard or `docker restart <container>`

#### **Domain Configuration Issues:**

```bash
# Check DNS configuration
dig cloudron.yourdomain.com
nslookup cloudron.yourdomain.com

# Verify domain ownership
./.agents/scripts/cloudron-helper.sh verify-domain production yourdomain.com

# Check SSL certificate status
./.agents/scripts/cloudron-helper.sh ssl-status production yourdomain.com
```

### **App-Specific Troubleshooting**

For app-specific issues, check these subagents:

- **Vaultwarden**: `../../tools/credentials/vaultwarden.md` - Password manager troubleshooting
- **WordPress**: `../../tools/wordpress/` - WordPress-specific issues

## 📊 **Monitoring & Management**

### **System Monitoring:**

```bash
# Get system status
./.agents/scripts/cloudron-helper.sh status production

# Check resource usage
./.agents/scripts/cloudron-helper.sh resources production

# Monitor app health
./.agents/scripts/cloudron-helper.sh health-check production

# Review system logs
./.agents/scripts/cloudron-helper.sh system-logs production
```

### **App Monitoring:**

```bash
# Monitor all apps
for app_id in $(./.agents/scripts/cloudron-helper.sh apps production | awk '{print $1}'); do
    echo "App $app_id status:"
    ./.agents/scripts/cloudron-helper.sh app-status production $app_id
done
```

## 🔄 **Backup & Recovery**

### **Backup Management:**

```bash
# Create system backup
./.agents/scripts/cloudron-helper.sh backup-system production

# List backups
./.agents/scripts/cloudron-helper.sh list-backups production

# Restore from backup
./.agents/scripts/cloudron-helper.sh restore-backup production backup-id

# Configure backup schedule
./.agents/scripts/cloudron-helper.sh configure-backups production daily
```

### **App-Specific Backups:**

```bash
# Backup specific app
./.agents/scripts/cloudron-helper.sh backup-app production app-id

# Restore app from backup
./.agents/scripts/cloudron-helper.sh restore-app production app-id backup-id

# Export app data
./.agents/scripts/cloudron-helper.sh export-app production app-id
```

## 📚 **Best Practices**

### **Server Management:**

1. **Regular maintenance**: Schedule regular maintenance windows
2. **Resource monitoring**: Monitor CPU, memory, and disk usage
3. **Update management**: Keep platform and apps updated
4. **Backup verification**: Regularly test backup and restore procedures
5. **Security audits**: Perform regular security audits

### **App Lifecycle:**

- **Staging first**: Test app installations and updates on staging
- **Gradual rollout**: Deploy changes gradually to production
- **Health monitoring**: Monitor app health and performance
- **Log management**: Regularly review and archive logs
- **Resource allocation**: Properly allocate resources per app

### **Domain Management:**

- **DNS automation**: Automate DNS configuration where possible
- **SSL monitoring**: Monitor SSL certificate expiration
- **Domain organization**: Organize domains by project or client
- **Access control**: Implement proper domain access controls

## 🎯 **AI Assistant Integration**

### **Automated Management:**

- **App deployment**: Automated application installation and configuration
- **Update orchestration**: Automated platform and app updates
- **Backup management**: Automated backup scheduling and verification
- **Resource optimization**: Automated resource allocation and scaling
- **Security monitoring**: Automated security scanning and compliance

### **Intelligent Operations:**

- **Predictive scaling**: AI-driven resource scaling recommendations
- **Anomaly detection**: Automated detection of unusual system behavior
- **Performance optimization**: Automated performance tuning recommendations
- **Cost optimization**: Automated cost analysis and optimization suggestions
- **Maintenance scheduling**: Intelligent maintenance window scheduling

---

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

**Cloudron provides a comprehensive app platform with excellent management capabilities, making it ideal for organizations needing easy-to-manage, self-hosted applications.**
