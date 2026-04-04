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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

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

```bash
# Instances and sites
./.agents/scripts/mainwp-helper.sh instances
./.agents/scripts/mainwp-helper.sh sites production
./.agents/scripts/mainwp-helper.sh site-details production 123
./.agents/scripts/mainwp-helper.sh monitor production
./.agents/scripts/mainwp-helper.sh site-status production 123
./.agents/scripts/mainwp-helper.sh sync production 123

# WordPress updates
./.agents/scripts/mainwp-helper.sh update-core production 123
./.agents/scripts/mainwp-helper.sh update-plugins production 123
./.agents/scripts/mainwp-helper.sh update-plugin production 123 akismet
./.agents/scripts/mainwp-helper.sh plugins production 123
./.agents/scripts/mainwp-helper.sh themes production 123

# Backups
./.agents/scripts/mainwp-helper.sh backup production 123 full   # or: db, files
./.agents/scripts/mainwp-helper.sh backups production 123

# Security
./.agents/scripts/mainwp-helper.sh security-scan production 123
./.agents/scripts/mainwp-helper.sh security-results production 123
./.agents/scripts/mainwp-helper.sh audit-security production 123
./.agents/scripts/mainwp-helper.sh uptime production 123

# Bulk operations
./.agents/scripts/mainwp-helper.sh bulk-update-wp production 123 124 125
./.agents/scripts/mainwp-helper.sh bulk-update-plugins production 123 124 125
```

## Troubleshooting

```bash
# API connection errors — verify credentials and SSL
./.agents/scripts/mainwp-helper.sh instances
curl -I https://mainwp.yourdomain.com/wp-json/mainwp/v1/
openssl s_client -connect mainwp.yourdomain.com:443

# Site sync issues — force sync and check child plugin is active
./.agents/scripts/mainwp-helper.sh sync production 123
./.agents/scripts/mainwp-helper.sh site-status production 123

# Update failures — check site details and uptime
./.agents/scripts/mainwp-helper.sh site-details production 123
./.agents/scripts/mainwp-helper.sh uptime production 123
```

## Monitoring Script

Daily routine covering updates, backups, and security alerts:

```bash
#!/bin/bash
INSTANCE="production"
SITES=$(./.agents/scripts/mainwp-helper.sh sites $INSTANCE | awk '{print $1}' | grep -E '^[0-9]+$')

echo "=== SITES NEEDING UPDATES ==="
./.agents/scripts/mainwp-helper.sh monitor $INSTANCE

echo "=== BACKUP STATUS ==="
for site_id in $SITES; do
    echo "Site $site_id:"
    ./.agents/scripts/mainwp-helper.sh backups $INSTANCE $site_id | tail -3
    ./.agents/scripts/mainwp-helper.sh backup $INSTANCE $site_id full
    sleep 30  # Rate limiting
done

echo "=== SECURITY ALERTS ==="
for site_id in $SITES; do
    results=$(./.agents/scripts/mainwp-helper.sh security-results $INSTANCE $site_id)
    if echo "$results" | grep -q "warning\|error\|critical"; then
        echo "Site $site_id has security issues:"
        echo "$results"
    fi
done
```
