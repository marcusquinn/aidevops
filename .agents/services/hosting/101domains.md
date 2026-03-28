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

# 101domains Registrar Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Domain registrar + DNS hosting (extensive TLD coverage)
- **Auth**: API key + secret + username
- **Config**: `configs/101domains-config.json`
- **Commands**: `101domains-helper.sh [accounts|domains|domain-details|dns-records|add-dns|update-dns|delete-dns|nameservers|update-ns|check-availability|contacts|lock|unlock|transfer-status|privacy-status|enable-privacy|disable-privacy|monitor-expiration|audit] [account] [domain] [args]`
- **Features**: WHOIS privacy, volume discounts, international TLDs
- **Bulk ops**: Iterate domains with `domains [account] | awk '{print $1}'`

<!-- AI-CONTEXT-END -->

## Configuration

Copy the template and add credentials:

```bash
cp configs/101domains-config.json.txt configs/101domains-config.json
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
    },
    "business": {
      "api_key": "YOUR_BUSINESS_101DOMAINS_API_KEY_HERE",
      "api_secret": "YOUR_BUSINESS_101DOMAINS_API_SECRET_HERE",
      "username": "business-101domains-username",
      "email": "business@company.com",
      "description": "Business domain account",
      "domains": ["company.com", "businessdomain.com"]
    }
  }
}
```

Get credentials: 101domains Control Panel → API Management → Generate API Key and Secret.

## Usage

### Account & Domain Info

```bash
# List accounts
./.agents/scripts/101domains-helper.sh accounts

# List domains for account
./.agents/scripts/101domains-helper.sh domains personal

# Domain details and full audit
./.agents/scripts/101domains-helper.sh domain-details personal example.com
./.agents/scripts/101domains-helper.sh audit personal example.com

# Check availability
./.agents/scripts/101domains-helper.sh check-availability personal newdomain.com

# Get contacts
./.agents/scripts/101domains-helper.sh contacts personal example.com
```

### DNS Management

```bash
# List records
./.agents/scripts/101domains-helper.sh dns-records personal example.com

# Add record
./.agents/scripts/101domains-helper.sh add-dns personal example.com www A 192.168.1.100 3600

# Update record
./.agents/scripts/101domains-helper.sh update-dns personal example.com record-id www A 192.168.1.101 3600

# Delete record
./.agents/scripts/101domains-helper.sh delete-dns personal example.com record-id
```

### Nameservers

```bash
# Get current nameservers
./.agents/scripts/101domains-helper.sh nameservers personal example.com

# Update to Cloudflare
./.agents/scripts/101domains-helper.sh update-ns personal example.com ns1.cloudflare.com ns2.cloudflare.com

# Update to Route 53
./.agents/scripts/101domains-helper.sh update-ns personal example.com \
  ns-1.awsdns-01.com ns-2.awsdns-02.net ns-3.awsdns-03.org ns-4.awsdns-04.co.uk
```

### Domain Lock & Transfer

```bash
./.agents/scripts/101domains-helper.sh lock personal example.com
./.agents/scripts/101domains-helper.sh unlock personal example.com
./.agents/scripts/101domains-helper.sh transfer-status personal example.com
```

### Privacy

```bash
./.agents/scripts/101domains-helper.sh privacy-status personal example.com
./.agents/scripts/101domains-helper.sh enable-privacy personal example.com
./.agents/scripts/101domains-helper.sh disable-privacy personal example.com
```

### Monitoring & Expiration

```bash
# Warn on domains expiring within N days
./.agents/scripts/101domains-helper.sh monitor-expiration personal 30
./.agents/scripts/101domains-helper.sh monitor-expiration personal 60
```

## Security

- Store credentials in `configs/101domains-config.json` (gitignored). Use `gopass` for secrets.
- Scope API keys to minimum required permissions. Rotate every 6–12 months.
- Lock all domains by default; unlock only during transfers.
- Enable WHOIS privacy on all domains.

```bash
# Security baseline for a domain
./.agents/scripts/101domains-helper.sh lock personal example.com
./.agents/scripts/101domains-helper.sh enable-privacy personal example.com
./.agents/scripts/101domains-helper.sh audit personal example.com
```

## Bulk Operations

```bash
# Audit all domains
for domain in $(./.agents/scripts/101domains-helper.sh domains personal | awk '{print $1}'); do
    ./.agents/scripts/101domains-helper.sh audit personal "$domain"
done

# Backup DNS records for all domains
for domain in $(./.agents/scripts/101domains-helper.sh domains personal | awk '{print $1}'); do
    ./.agents/scripts/101domains-helper.sh dns-records personal "$domain" \
      > "dns-backup-$domain-$(date +%Y%m%d).txt"
done

# Check privacy status across portfolio
for domain in $(./.agents/scripts/101domains-helper.sh domains personal | awk '{print $1}'); do
    echo "$domain: $(./.agents/scripts/101domains-helper.sh privacy-status personal "$domain")"
done
```

## Troubleshooting

**API auth errors** — verify credentials with `accounts` command; check API permissions in the control panel.

**DNS issues** — check records and nameservers, then verify propagation:

```bash
./.agents/scripts/101domains-helper.sh dns-records personal example.com
./.agents/scripts/101domains-helper.sh nameservers personal example.com
dig @8.8.8.8 example.com
```

**Transfer blocked** — domain must be unlocked and contacts verified:

```bash
./.agents/scripts/101domains-helper.sh audit personal example.com
./.agents/scripts/101domains-helper.sh transfer-status personal example.com
./.agents/scripts/101domains-helper.sh contacts personal example.com
```
