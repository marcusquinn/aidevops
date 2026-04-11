---
description: Check IP reputation before using VPS/server/proxy IPs
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Arguments: $ARGUMENTS. Helper: `~/.aidevops/agents/scripts/ip-reputation-helper.sh`

## Commands

- `1.2.3.4` → `check "$IP"`
- `1.2.3.4 -f json` → `check "$IP" -f json`
- `1.2.3.4 report` → `report "$IP"`
- `1.2.3.4 --provider abuseipdb` → `check "$IP" --provider "$PROVIDER"`
- `ips.txt` → `batch "$FILE"`
- `ips.txt --dnsbl-overlap` → `batch "$FILE" --dnsbl-overlap`
- `1.2.3.4 --no-cache` → `check "$IP" --no-cache`
- no args → show usage

Ops: `providers`, `cache-stats`, `cache-clear [--provider P] [--ip IP]`, `rate-limit-status`, `help`.

## Output

```text
IP Reputation: 1.2.3.4
Risk Level:  CLEAN (score: 2/100)
Verdict:     SAFE — no significant flags detected

Providers (8/10 responded):
  Spamhaus DNSBL    clean   (0)
  AbuseIPDB         clean   (0)
  IPQualityScore    clean   (2)
  ...

Flags: Tor=NO  Proxy=NO  VPN=NO
```

Providers: Spamhaus DNSBL, ProxyCheck.io, StopForumSpam, Blocklist.de, GreyNoise, AbuseIPDB, IPQualityScore, Scamalytics. After results, offer: full report, single-provider recheck, batch check, raw JSON, or cache-clear recheck.

## Related

- `tools/security/ip-reputation.md` — full documentation and provider reference
- `tools/security/tirith.md` — terminal security guard
- `tools/security/cdn-origin-ip.md` — CDN origin IP leak detection
- `/email-health-check` — email DNSBL and deliverability check
