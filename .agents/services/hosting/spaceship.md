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
- **Config**: `configs/spaceship-config.json` (copy from `configs/spaceship-config.json.txt`)
- **Commands**: `spaceship-helper.sh [accounts|domains|domain-details|dns-records|add-dns|update-dns|delete-dns|nameservers|update-ns|check-availability|contacts|lock|unlock|transfer-status|monitor-expiration|audit] [account] [domain] [args]`
- **DNS records**: A, AAAA, CNAME, MX, TXT, NS
- **Security**: Domain locking, privacy protection, DNSSEC
- **API key storage**: `setup-local-api-keys.sh set spaceship YOUR_API_KEY`
- **Monitoring**: `monitor-expiration [account] [days]` for renewal alerts

<!-- AI-CONTEXT-END -->

## Setup

Credentials: Spaceship Dashboard → API Settings → Generate Key + Secret. Store: `setup-local-api-keys.sh set spaceship YOUR_API_KEY`. Test: `spaceship-helper.sh accounts`.

Config schema: `configs/spaceship-config.json.txt` — copy to `configs/spaceship-config.json` and fill in `api_key`, `api_secret`, `email`, `domains`.

## Commands

```bash
# Account + domain info
spaceship-helper.sh accounts
spaceship-helper.sh domains personal
spaceship-helper.sh domain-details personal example.com
spaceship-helper.sh audit personal example.com

# DNS management
spaceship-helper.sh dns-records personal example.com
spaceship-helper.sh add-dns personal example.com www A 192.168.1.100 3600
spaceship-helper.sh update-dns personal example.com record-id www A 192.168.1.101 3600
spaceship-helper.sh delete-dns personal example.com record-id

# Nameservers (Cloudflare example; Route 53 takes 4 NS args)
spaceship-helper.sh nameservers personal example.com
spaceship-helper.sh update-ns personal example.com ns1.cloudflare.com ns2.cloudflare.com

# Domain management
spaceship-helper.sh check-availability personal newdomain.com
spaceship-helper.sh contacts personal example.com
spaceship-helper.sh lock personal example.com
spaceship-helper.sh unlock personal example.com
spaceship-helper.sh transfer-status personal example.com

# Monitoring + backup
spaceship-helper.sh monitor-expiration personal 30
spaceship-helper.sh dns-records personal example.com > dns-backup-$(date +%Y%m%d).txt
spaceship-helper.sh domains personal > domains-backup-$(date +%Y%m%d).txt
```

## Security

- Separate API keys per project; rotate every 6–12 months; minimal permissions
- Store in `~/.config/aidevops/` only — never commit to repository files
- Enable domain lock (`lock` command) and DNSSEC; monitor records for unauthorized changes

## Troubleshooting

| Issue | Command |
|-------|---------|
| Auth errors | `spaceship-helper.sh accounts` |
| DNS propagation | `spaceship-helper.sh dns-records personal example.com` + `dig @8.8.8.8 example.com` |
| Domain issues | `spaceship-helper.sh audit personal example.com` |
| Transfer status | `spaceship-helper.sh transfer-status personal example.com` |
