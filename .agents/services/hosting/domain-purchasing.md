---
description: Domain purchasing and management guide
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Domain Purchasing & Management Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

**Registrars**:
- **Spaceship**: 500+ TLDs, bulk ops, auto-renewal — full API support
- **101domains**: 1000+ TLDs, premium domains, reseller support — comprehensive API

**Commands** (`spaceship-helper.sh`):
- `check-availability <account> <domain>` — check single domain
- `bulk-check <account> <domains...>` — check multiple domains
- `purchase <account> <domain> <years> <auto_renew>` — buy domain (requires confirmation)
- `domains <account>` — list registered domains
- `domain-details <account> <domain>` — domain details
- `monitor-expiration <account> <days>` — check expiring domains

**Security**: confirmation required on every purchase; configure `max_purchase_amount` and `daily_purchase_limit` to cap spend; all purchases logged and auditable; enable domain locking and 2FA on registrar account

**TLD Recommendations**:
- Web apps: `.com`, `.app`, `.io`
- Tech: `.dev`, `.tech`, `.ai`
- E-commerce: `.shop`, `.store`

<!-- AI-CONTEXT-END -->

## Configuration

```json
{
  "accounts": {
    "personal": {
      "api_token": "YOUR_SPACESHIP_API_TOKEN_HERE",
      "email": "your-email@domain.com",
      "auto_renew_default": true,
      "default_years": 1,
      "purchasing_enabled": true
    }
  },
  "purchasing_settings": {
    "confirmation_required": true,
    "max_purchase_amount": 500,
    "daily_purchase_limit": 10,
    "require_approval_over": 100,
    "auto_configure_dns": true,
    "default_nameservers": ["ns1.spaceship.com", "ns2.spaceship.com"]
  }
}
```

## Usage

### Availability Checking

```bash
./.agents/scripts/spaceship-helper.sh check-availability personal example.com

./.agents/scripts/spaceship-helper.sh bulk-check personal \
  myproject.com myproject.net myproject.io myproject.app myproject.dev
```

### Purchasing

```bash
# 1 year with auto-renewal
./.agents/scripts/spaceship-helper.sh purchase personal mynewdomain.com 1 true

# Multi-year
./.agents/scripts/spaceship-helper.sh purchase personal longterm-project.com 3 true

# Without auto-renewal
./.agents/scripts/spaceship-helper.sh purchase personal temporary-project.com 1 false
```

### Portfolio Management

```bash
./.agents/scripts/spaceship-helper.sh domains personal
./.agents/scripts/spaceship-helper.sh domain-details personal mydomain.com
./.agents/scripts/spaceship-helper.sh monitor-expiration personal 30
```

## Integration with Development Workflow

Complete project setup with domain:

```bash
# 1. Research and purchase
./.agents/scripts/spaceship-helper.sh bulk-check personal myproject.com myproject.dev
./.agents/scripts/spaceship-helper.sh purchase personal myproject.com 1 true

# 2. DNS configuration
./.agents/scripts/dns-helper.sh add cloudflare personal myproject.com @ A 192.168.1.100
./.agents/scripts/dns-helper.sh add cloudflare personal myproject.com www CNAME myproject.com

# 3. SSL — automatic with Cloudflare or manual certificate installation

# 4. Deploy
./.agents/scripts/coolify-helper.sh deploy production myproject myproject.com
```

Multi-environment strategy:

```bash
./.agents/scripts/spaceship-helper.sh purchase personal myproject.com 1 true   # Production
./.agents/scripts/spaceship-helper.sh purchase personal myproject.dev 1 true   # Development
./.agents/scripts/spaceship-helper.sh purchase personal myproject.app 1 true   # Mobile app
```

## AI Assistant Workflow

When asked to purchase a domain: analyse project type → suggest name candidates → bulk-check availability across recommended TLDs → compare pricing and renewal costs → present recommendation with rationale → execute after explicit user confirmation → configure DNS and add domain to project config.

## Portfolio Best Practices

- **Auto-renewal**: enable for production domains; review annually
- **Expiration monitoring**: run `monitor-expiration` with 60-day lead time
- **Multi-year registration**: reduces renewal risk for long-lived projects
- **DNS documentation**: record purpose and owner for each domain
- **Portfolio review**: drop unused domains at renewal time
