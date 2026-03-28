---
description: MainWP WordPress fleet management - bulk updates, backups, security scans, and monitoring across multiple WordPress sites via REST API
mode: subagent
temperature: 0.1
tools:
  bash: true
  read: true
  write: true
  edit: true
  glob: true
  grep: true
  task: true
---

# MainWP WordPress Management Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Self-hosted WordPress site management platform
- **Auth**: consumer_key + consumer_secret via REST API
- **Config**: `configs/mainwp-config.json`
- **Commands**: `mainwp-helper.sh [instances|sites|site-details|monitor|update-core|update-plugins|plugins|themes|backup|backups|security-scan|security-results|audit-security|sync] [instance] [site-id] [args]`
- **Requires**: MainWP Dashboard + REST API Extension + MainWP Child plugin on sites
- **API test**: `curl -I https://mainwp.yourdomain.com/wp-json/mainwp/v1/`
- **Bulk ops**: `bulk-update-wp`, `bulk-update-plugins` for multiple site IDs
- **Backup types**: full, db, files
- **Related**: `@wp-admin` (calls this for fleet management), `@wp-preferred` (plugin recommendations)

<!-- AI-CONTEXT-END -->

## Configuration

```bash
cp configs/mainwp-config.json.txt configs/mainwp-config.json
```

```json
{
  "instances": {
    "production": {
      "base_url": "https://mainwp.yourdomain.com",
      "consumer_key": "YOUR_MAINWP_CONSUMER_KEY_HERE",
      "consumer_secret": "YOUR_MAINWP_CONSUMER_SECRET_HERE",
      "description": "Production MainWP instance",
      "managed_sites_count": 25
    },
    "staging": {
      "base_url": "https://staging-mainwp.yourdomain.com",
      "consumer_key": "YOUR_STAGING_MAINWP_CONSUMER_KEY_HERE",
      "consumer_secret": "YOUR_STAGING_MAINWP_CONSUMER_SECRET_HERE",
      "description": "Staging MainWP instance",
      "managed_sites_count": 5
    }
  }
}
```

Setup: install MainWP Dashboard → REST API Extension → generate credentials → install MainWP Child plugin on each site.

## Commands

### Basic

```bash
# List all MainWP instances
./.agents/scripts/mainwp-helper.sh instances

# List all managed sites
./.agents/scripts/mainwp-helper.sh sites production

# Get site details
./.agents/scripts/mainwp-helper.sh site-details production 123

# Monitor all sites
./.agents/scripts/mainwp-helper.sh monitor production
```

### WordPress Management

```bash
# Update WordPress core for a site
./.agents/scripts/mainwp-helper.sh update-core production 123

# Update all plugins for a site
./.agents/scripts/mainwp-helper.sh update-plugins production 123

# Update specific plugin
./.agents/scripts/mainwp-helper.sh update-plugin production 123 akismet

# List site plugins
./.agents/scripts/mainwp-helper.sh plugins production 123

# List site themes
./.agents/scripts/mainwp-helper.sh themes production 123
```

### Backup Management

```bash
# Create full backup
./.agents/scripts/mainwp-helper.sh backup production 123 full

# Create database backup
./.agents/scripts/mainwp-helper.sh backup production 123 db

# Create files backup
./.agents/scripts/mainwp-helper.sh backup production 123 files

# List all backups
./.agents/scripts/mainwp-helper.sh backups production 123
```

### Security

```bash
# Run security scan
./.agents/scripts/mainwp-helper.sh security-scan production 123

# Get security scan results
./.agents/scripts/mainwp-helper.sh security-results production 123

# Comprehensive security audit
./.agents/scripts/mainwp-helper.sh audit-security production 123

# Get uptime status
./.agents/scripts/mainwp-helper.sh uptime production 123
```

### Bulk Operations

```bash
# Bulk WordPress core updates
./.agents/scripts/mainwp-helper.sh bulk-update-wp production 123 124 125

# Bulk plugin updates
./.agents/scripts/mainwp-helper.sh bulk-update-plugins production 123 124 125

# Sync multiple sites
for site_id in 123 124 125; do
    ./.agents/scripts/mainwp-helper.sh sync production $site_id
done
```

### Site Monitoring

```bash
# Get site status
./.agents/scripts/mainwp-helper.sh site-status production 123

# Sync site data
./.agents/scripts/mainwp-helper.sh sync production 123

# Monitor all sites overview
./.agents/scripts/mainwp-helper.sh monitor production
```

## Troubleshooting

### API Connection Errors

```bash
# Verify API credentials
./.agents/scripts/mainwp-helper.sh instances

# Check MainWP instance accessibility
curl -I https://mainwp.yourdomain.com/wp-json/mainwp/v1/

# Verify SSL certificate
openssl s_client -connect mainwp.yourdomain.com:443
```

### Site Sync Issues

```bash
# Force site sync
./.agents/scripts/mainwp-helper.sh sync production 123

# Check site status
./.agents/scripts/mainwp-helper.sh site-status production 123

# Verify child plugin is active on target site
```

### Update Failures

```bash
# Check site details for error messages
./.agents/scripts/mainwp-helper.sh site-details production 123

# Verify site accessibility
./.agents/scripts/mainwp-helper.sh uptime production 123

# Check for maintenance mode or plugin conflicts
```

## Monitoring Scripts

### Daily monitoring routine

```bash
#!/bin/bash
INSTANCE="production"

echo "=== SITES NEEDING UPDATES ==="
./.agents/scripts/mainwp-helper.sh monitor $INSTANCE

echo "=== BACKUP STATUS ==="
for site_id in $(./.agents/scripts/mainwp-helper.sh sites $INSTANCE | awk '{print $1}' | grep -E '^[0-9]+$'); do
    echo "Site $site_id backups:"
    ./.agents/scripts/mainwp-helper.sh backups $INSTANCE $site_id | tail -5
done

echo "=== SECURITY ALERTS ==="
for site_id in $(./.agents/scripts/mainwp-helper.sh sites $INSTANCE | awk '{print $1}' | grep -E '^[0-9]+$'); do
    security_results=$(./.agents/scripts/mainwp-helper.sh security-results $INSTANCE $site_id)
    if echo "$security_results" | grep -q "warning\|error\|critical"; then
        echo "Site $site_id has security issues:"
        echo "$security_results"
    fi
done
```

### Daily backup routine

```bash
#!/bin/bash
INSTANCE="production"

for site_id in $(./.agents/scripts/mainwp-helper.sh sites $INSTANCE | awk '{print $1}' | grep -E '^[0-9]+$'); do
    echo "Creating backup for site $site_id"
    ./.agents/scripts/mainwp-helper.sh backup $INSTANCE $site_id full
    sleep 30  # Rate limiting
done
```

### Backup verification

```bash
for site_id in $(./.agents/scripts/mainwp-helper.sh sites production | awk '{print $1}' | grep -E '^[0-9]+$'); do
    echo "Backup status for site $site_id:"
    ./.agents/scripts/mainwp-helper.sh backups production $site_id | head -3
done
```
