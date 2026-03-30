---
description: DNS provider configuration and management
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

# DNS Providers Configuration Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Providers**: Cloudflare, Namecheap, Route 53
- **Unified command**: `dns-helper.sh [command] [provider] [account] [domain] [args]`
- **Configs**: `configs/{cloudflare,namecheap,route53}-dns-config.json` (copy from `.json.txt` templates)
- **Record types**: A, AAAA, CNAME, MX, TXT, CAA, NS
- **Security**: API tokens minimal-permission, rotate 6-12 months; MFA; DNSSEC; CAA records

<!-- AI-CONTEXT-END -->

## Config

Each provider has a `.json.txt` template in `configs/`. Copy and customize:

```bash
cp configs/cloudflare-dns-config.json.txt configs/cloudflare-dns-config.json
# Edit with your credentials — see template for required fields:
#   Cloudflare: api_token, email
#   Namecheap:  api_user, api_key, client_ip
#   Route 53:   aws_access_key_id, aws_secret_access_key, region
```

## Commands

| Category | Commands |
|----------|----------|
| CRUD | `records`, `add`, `update`, `delete` |
| Cloudflare | `proxy-enable`, `page-rule`, `analytics` |
| Route 53 | `health-check`, `weighted-routing`, `geo-routing` |
| Security | `enable-dnssec`, `test-auth`, `check-permissions` |
| Diagnostics | `propagation-check`, `ttl-check`, `conflict-check`, `validate`, `compare` |
| Monitoring | `monitor-resolution`, `performance-check`, `change-log`, `report` |
| Migration | `export`, `import`, `compare` |
| Backup | `backup`, `restore`, `schedule-backup` |

## Usage

```bash
# CRUD — dns-helper.sh [command] [provider] [account] [domain] [name] [type] [value]
dns-helper.sh records cloudflare personal example.com
dns-helper.sh add cloudflare personal example.com www A 192.168.1.100
dns-helper.sh update cloudflare personal example.com record-id www A 192.168.1.200
dns-helper.sh delete cloudflare personal example.com record-id

# Provider-specific
dns-helper.sh health-check route53 production example.com https://example.com/health
dns-helper.sh proxy-enable cloudflare personal example.com record-id

# Security
dns-helper.sh enable-dnssec cloudflare personal example.com
dns-helper.sh add cloudflare personal example.com @ CAA "0 issue letsencrypt.org"

# Migration: export → import → verify
dns-helper.sh export namecheap personal example.com > source-dns.json
dns-helper.sh import cloudflare personal example.com source-dns.json
dns-helper.sh compare example.com namecheap:personal cloudflare:personal

# Troubleshooting
dns-helper.sh propagation-check example.com
dns-helper.sh validate cloudflare personal example.com
```
