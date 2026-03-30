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
- **Unified command**: `dns-helper.sh [records|add|update|delete] [provider] [account] [domain] [args]`
- **Configs**: `cloudflare-dns-config.json`, `namecheap-dns-config.json`, `route53-dns-config.json`
- **Cloudflare**: API token auth, proxy support, analytics
- **Namecheap**: API user + key + whitelisted IP
- **Route 53**: AWS IAM credentials, health checks, geo/weighted routing
- **Record types**: A, AAAA, CNAME, MX, TXT, CAA, NS
- **Operations**: `propagation-check`, `export`, `import`, `backup`, `compare`
- **Security**: API tokens minimal-permission, rotate 6-12 months; MFA on all accounts; DNSSEC; CAA records; audit logging

<!-- AI-CONTEXT-END -->

## Configuration

**Cloudflare** (`configs/cloudflare-dns-config.json`):

```json
{
  "accounts": {
    "personal": {
      "api_token": "YOUR_CLOUDFLARE_API_TOKEN_HERE",
      "email": "your-email@domain.com"
    }
  }
}
```

**Namecheap** (`configs/namecheap-dns-config.json`):

```json
{
  "accounts": {
    "personal": {
      "api_user": "your-namecheap-username",
      "api_key": "YOUR_NAMECHEAP_API_KEY_HERE",
      "client_ip": "YOUR_WHITELISTED_IP_HERE"
    }
  }
}
```

**Route 53** (`configs/route53-dns-config.json`):

```json
{
  "accounts": {
    "production": {
      "aws_access_key_id": "YOUR_AWS_ACCESS_KEY_ID_HERE",
      "aws_secret_access_key": "YOUR_AWS_SECRET_ACCESS_KEY_HERE",
      "region": "us-east-1"
    }
  }
}
```

## Usage

```bash
# CRUD — [provider] [account] [domain] [name] [type] [value]
./.agents/scripts/dns-helper.sh records cloudflare personal example.com
./.agents/scripts/dns-helper.sh add cloudflare personal example.com www A 192.168.1.100
./.agents/scripts/dns-helper.sh update cloudflare personal example.com record-id www A 192.168.1.200
./.agents/scripts/dns-helper.sh delete cloudflare personal example.com record-id

# Cloudflare-specific
./.agents/scripts/dns-helper.sh proxy-enable cloudflare personal example.com record-id
./.agents/scripts/dns-helper.sh page-rule cloudflare personal example.com "*.example.com/*" cache-everything
./.agents/scripts/dns-helper.sh analytics cloudflare personal example.com

# Route 53-specific
./.agents/scripts/dns-helper.sh health-check route53 production example.com https://example.com/health
./.agents/scripts/dns-helper.sh weighted-routing route53 production example.com www A 192.168.1.100 50
./.agents/scripts/dns-helper.sh geo-routing route53 production example.com www A 192.168.1.100 US
```

## Security

```bash
# DNSSEC
./.agents/scripts/dns-helper.sh enable-dnssec cloudflare personal example.com

# CAA record (restrict certificate issuance)
./.agents/scripts/dns-helper.sh add cloudflare personal example.com @ CAA "0 issue letsencrypt.org"

# Auth test / permission check
./.agents/scripts/dns-helper.sh test-auth cloudflare personal
./.agents/scripts/dns-helper.sh check-permissions cloudflare personal
```

## Troubleshooting

```bash
# Propagation
dig @8.8.8.8 example.com
./.agents/scripts/dns-helper.sh propagation-check example.com
./.agents/scripts/dns-helper.sh ttl-check example.com

# Conflicts / validation
./.agents/scripts/dns-helper.sh conflict-check cloudflare personal example.com
./.agents/scripts/dns-helper.sh validate cloudflare personal example.com
./.agents/scripts/dns-helper.sh compare example.com cloudflare:personal namecheap:personal
```

## Operations

```bash
# Monitoring / reporting
./.agents/scripts/dns-helper.sh monitor-resolution example.com
./.agents/scripts/dns-helper.sh performance-check example.com
./.agents/scripts/dns-helper.sh change-log cloudflare personal example.com
./.agents/scripts/dns-helper.sh report cloudflare personal example.com

# Migration: export → import
./.agents/scripts/dns-helper.sh export namecheap personal example.com > source-dns.json
./.agents/scripts/dns-helper.sh import cloudflare personal example.com source-dns.json
./.agents/scripts/dns-helper.sh compare example.com namecheap:personal cloudflare:personal

# Backup / restore
./.agents/scripts/dns-helper.sh backup cloudflare personal example.com
./.agents/scripts/dns-helper.sh restore cloudflare personal example.com backup-file.json
./.agents/scripts/dns-helper.sh schedule-backup cloudflare personal daily
```
