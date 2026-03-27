---
description: Spaceship domain registrar integration
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

# Spaceship Domain Registrar Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Domain registrar + DNS hosting
- **Auth**: API key + secret
- **Config**: `configs/spaceship-config.json`
- **Commands**: `spaceship-helper.sh [accounts|domains|domain-details|dns-records|add-dns|update-dns|delete-dns|nameservers|update-ns|check-availability|contacts|lock|unlock|transfer-status|monitor-expiration|audit] [account] [domain] [args]`
- **DNS records**: A, AAAA, CNAME, MX, TXT, NS
- **Security**: Domain locking, privacy protection, DNSSEC
- **API key storage**: `setup-local-api-keys.sh set spaceship YOUR_API_KEY`
- **Monitoring**: `monitor-expiration [account] [days]` for renewal alerts

<!-- AI-CONTEXT-END -->

## Configuration

```bash
cp configs/spaceship-config.json.txt configs/spaceship-config.json
```

Multi-account config structure:

```json
{
  "accounts": {
    "personal": {
      "api_key": "YOUR_SPACESHIP_API_KEY_HERE",
      "api_secret": "YOUR_SPACESHIP_API_SECRET_HERE",
      "email": "your-email@domain.com",
      "description": "Personal domain account",
      "domains": ["yourdomain.com", "anotherdomain.com"]
    },
    "business": {
      "api_key": "YOUR_BUSINESS_SPACESHIP_API_KEY_HERE",
      "api_secret": "YOUR_BUSINESS_SPACESHIP_API_SECRET_HERE",
      "email": "business@company.com",
      "description": "Business domain account",
      "domains": ["company.com", "businessdomain.com"]
    }
  }
}
```

API credentials setup:

1. Login to Spaceship Dashboard → API Settings → Generate API Key and Secret
2. Store: `bash .agents/scripts/setup-local-api-keys.sh set spaceship YOUR_API_KEY`
3. Test with `spaceship-helper.sh accounts`

## Usage

### Basic Commands

```bash
./.agents/scripts/spaceship-helper.sh accounts
./.agents/scripts/spaceship-helper.sh domains personal
./.agents/scripts/spaceship-helper.sh domain-details personal example.com
./.agents/scripts/spaceship-helper.sh audit personal example.com
```

### DNS Management

```bash
./.agents/scripts/spaceship-helper.sh dns-records personal example.com
./.agents/scripts/spaceship-helper.sh add-dns personal example.com www A 192.168.1.100 3600
./.agents/scripts/spaceship-helper.sh update-dns personal example.com record-id www A 192.168.1.101 3600
./.agents/scripts/spaceship-helper.sh delete-dns personal example.com record-id
```

### Nameserver Management

```bash
./.agents/scripts/spaceship-helper.sh nameservers personal example.com

# Cloudflare
./.agents/scripts/spaceship-helper.sh update-ns personal example.com ns1.cloudflare.com ns2.cloudflare.com

# Route 53
./.agents/scripts/spaceship-helper.sh update-ns personal example.com ns-1.awsdns-01.com ns-2.awsdns-02.net ns-3.awsdns-03.org ns-4.awsdns-04.co.uk
```

### Domain Management

```bash
./.agents/scripts/spaceship-helper.sh check-availability personal newdomain.com
./.agents/scripts/spaceship-helper.sh contacts personal example.com
./.agents/scripts/spaceship-helper.sh lock personal example.com
./.agents/scripts/spaceship-helper.sh unlock personal example.com
./.agents/scripts/spaceship-helper.sh transfer-status personal example.com
```

### Monitoring

```bash
./.agents/scripts/spaceship-helper.sh monitor-expiration personal 30
./.agents/scripts/spaceship-helper.sh monitor-expiration personal 60

# Audit multiple domains
for domain in example.com another.com; do
    ./.agents/scripts/spaceship-helper.sh audit personal "$domain"
done
```

Automated expiration check script:

```bash
#!/bin/bash
ACCOUNT="personal"
THRESHOLD=30
EXPIRING=$(./.agents/scripts/spaceship-helper.sh monitor-expiration "$ACCOUNT" "$THRESHOLD")
if [[ -n "$EXPIRING" ]]; then
    echo "Domains expiring soon:"
    echo "$EXPIRING"
fi
```

## Security

**API keys:**

- Separate keys per project; rotate every 6–12 months
- Minimal permissions; store in `~/.config/aidevops/` only
- Never commit to repository files

**Domain security:**

```bash
./.agents/scripts/spaceship-helper.sh lock personal example.com
./.agents/scripts/spaceship-helper.sh transfer-status personal example.com
./.agents/scripts/spaceship-helper.sh audit personal example.com
```

**DNS security:** Enable DNSSEC; monitor records for unauthorized changes; limit API access to trusted systems.

## Troubleshooting

**API auth errors:**

```bash
# Verify credentials and permissions
./.agents/scripts/spaceship-helper.sh accounts
```

**DNS propagation issues:**

```bash
./.agents/scripts/spaceship-helper.sh dns-records personal example.com
./.agents/scripts/spaceship-helper.sh nameservers personal example.com
dig @8.8.8.8 example.com
nslookup example.com 8.8.8.8
```

**Domain issues:**

```bash
./.agents/scripts/spaceship-helper.sh domain-details personal example.com
./.agents/scripts/spaceship-helper.sh audit personal example.com
./.agents/scripts/spaceship-helper.sh transfer-status personal example.com
```

## Backup

```bash
# DNS records
./.agents/scripts/spaceship-helper.sh dns-records personal example.com > dns-backup-example.com-$(date +%Y%m%d).txt

# Domain list
./.agents/scripts/spaceship-helper.sh domains personal > domains-backup-$(date +%Y%m%d).txt

# Nameservers
./.agents/scripts/spaceship-helper.sh nameservers personal example.com > ns-backup-example.com-$(date +%Y%m%d).txt
```

## Best Practices

- Monitor expiration dates; enable domain lock and privacy protection
- Validate DNS records before applying; make changes gradually; monitor propagation
- Test DNS changes in staging first; maintain rollback procedures
- Document DNS architecture and all changes
