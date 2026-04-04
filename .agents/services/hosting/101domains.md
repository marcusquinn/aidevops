---
description: 101domains registrar integration
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

# 101domains Registrar Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Domain registrar + DNS hosting (extensive TLD coverage)
- **Auth**: API key + secret + username
- **Config**: `configs/101domains-config.json`
- **Commands**: `101domains-helper.sh [accounts|domains|domain-details|dns-records|add-dns|update-dns|delete-dns|nameservers|update-ns|check-availability|contacts|lock|unlock|transfer-status|privacy-status|enable-privacy|disable-privacy|monitor-expiration|audit] [account] [domain] [args]`
- **Best for**: Large portfolios, diverse TLDs, international businesses, domain resellers, privacy-focused management
- **Features**: WHOIS privacy, volume discounts, international TLDs, full REST API
- **Bulk ops**: Iterate domains with `domains [account] | awk '{print $1}'`

<!-- AI-CONTEXT-END -->

## Configuration

```bash
cp configs/101domains-config.json.txt configs/101domains-config.json
# Edit with your API credentials from 101domains Control Panel > API Management
```

```json
{
  "accounts": {
    "personal": {
      "api_key": "YOUR_101DOMAINS_API_KEY_HERE",
      "api_secret": "YOUR_101DOMAINS_API_SECRET_HERE",
      "username": "your-101domains-username",
      "email": "your-email@domain.com",
      "description": "Personal domain account",
      "domains": ["yourdomain.com", "anotherdomain.com"]
    }
  }
}
```

Add additional account blocks (e.g. `"business": { ... }`) as needed — same structure.

## Security

- Store API credentials in `configs/101domains-config.json` (gitignored) or gopass
- Scope API keys to minimum required permissions; rotate every 6-12 months
- Lock all domains by default; unlock only during active transfers
- Enable WHOIS privacy on all domains

```bash
# Harden a domain
101domains-helper.sh lock personal example.com
101domains-helper.sh enable-privacy personal example.com
101domains-helper.sh audit personal example.com
```

## Usage

```bash
# Account and domain listing
101domains-helper.sh accounts
101domains-helper.sh domains personal
101domains-helper.sh domain-details personal example.com
101domains-helper.sh audit personal example.com

# DNS management
101domains-helper.sh dns-records personal example.com
101domains-helper.sh add-dns personal example.com www A 192.168.1.100 3600
101domains-helper.sh update-dns personal example.com record-id www A 192.168.1.101 3600
101domains-helper.sh delete-dns personal example.com record-id

# Nameservers
101domains-helper.sh nameservers personal example.com
101domains-helper.sh update-ns personal example.com ns1.cloudflare.com ns2.cloudflare.com
101domains-helper.sh update-ns personal example.com ns-1.awsdns-01.com ns-2.awsdns-02.net ns-3.awsdns-03.org ns-4.awsdns-04.co.uk

# Domain management
101domains-helper.sh check-availability personal newdomain.com
101domains-helper.sh contacts personal example.com
101domains-helper.sh lock personal example.com
101domains-helper.sh unlock personal example.com
101domains-helper.sh transfer-status personal example.com

# Privacy
101domains-helper.sh privacy-status personal example.com
101domains-helper.sh enable-privacy personal example.com
101domains-helper.sh disable-privacy personal example.com
```

## Monitoring & Automation

```bash
# Expiration monitoring (days threshold)
101domains-helper.sh monitor-expiration personal 30

# Portfolio-wide privacy audit
for domain in $(101domains-helper.sh domains personal | awk '{print $1}'); do
    echo "$domain: $(101domains-helper.sh privacy-status personal "$domain")"
done

# Backup DNS + audit for all domains
for domain in $(101domains-helper.sh domains personal | awk '{print $1}'); do
    101domains-helper.sh dns-records personal "$domain" > "dns-backup-$domain-$(date +%Y%m%d).txt"
    101domains-helper.sh audit personal "$domain" > "audit-$domain-$(date +%Y%m%d).txt"
done
```

## Troubleshooting

| Symptom | Command |
|---------|---------|
| Auth error | `101domains-helper.sh accounts` — verify key/secret/username in config |
| DNS not resolving | `dns-records` → `nameservers` → `dig @8.8.8.8 example.com` |
| Transfer blocked | `audit` → `transfer-status` → `contacts` — check lock status and contact accuracy |
