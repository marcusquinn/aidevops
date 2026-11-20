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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Spaceship Domain Registrar Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Type**: Domain registrar + DNS hosting
- **Auth**: API key + secret, sent as `X-API-Key` and `X-API-Secret` headers to `https://spaceship.dev/api/v1` ([docs](https://docs.spaceship.dev/))
- **Credentials**: `aidevops secret` names `SPACESHIP_<ACCOUNT>_API_KEY` + `SPACESHIP_<ACCOUNT>_API_SECRET` (account upper-cased, non-alphanumerics → `_`)
- **Config (fallback)**: `configs/spaceship-config.json` (copy from `configs/spaceship-config.json.txt`); resolved from the script directory, works from any cwd
- **Commands**: `spaceship-helper.sh [accounts|domains|domain-details|dns-records|add-dns|update-dns|delete-dns|nameservers|update-ns|check-availability|contacts|lock|unlock|transfer-status|monitor-expiration|audit] [account] [domain] [args]`
- **DNS records**: A, AAAA, CNAME, MX, TXT, NS
- **Security**: Domain locking, privacy protection, DNSSEC
- **API key storage**: `aidevops secret set SPACESHIP_PERSONAL_API_KEY` and `aidevops secret set SPACESHIP_PERSONAL_API_SECRET` (prompts; never paste values in chat)
- **Monitoring**: `monitor-expiration [account] [days]` for renewal alerts

<!-- AI-CONTEXT-END -->

## Setup

Spaceship Dashboard → API Manager → New API key (grant `domains:read`, plus `domains:write` / `dnsrecords:*` as needed). Store both values with `aidevops secret set` (names above), then run the helper through secret injection so values never appear in output:

```bash
aidevops secret SPACESHIP_PERSONAL_API_KEY SPACESHIP_PERSONAL_API_SECRET -- \
  .agents/scripts/spaceship-helper.sh domain-details personal example.com
```

Fallback: copy `configs/spaceship-config.json.txt` → `configs/spaceship-config.json`, fill `api_key`, `api_secret`. Test: `spaceship-helper.sh accounts`.

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
spaceship-helper.sh update-dns personal example.com - www A 192.168.1.101 3600   # upsert by name/type; id unused
spaceship-helper.sh delete-dns personal example.com www A 192.168.1.101           # matched by value

# Nameservers (Cloudflare example; Route 53 takes 4 NS args; `basic` = Spaceship DNS)
spaceship-helper.sh nameservers personal example.com
spaceship-helper.sh update-ns personal example.com ns1.cloudflare.com ns2.cloudflare.com --dry-run   # print request only
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
