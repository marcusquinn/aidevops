---
description: Check IP reputation before using VPS/server/proxy IPs
agent: Build+
mode: subagent
---

Arguments: `$ARGUMENTS`

Always route through `~/.aidevops/agents/scripts/ip-reputation-helper.sh`.

## Route map

| Input | Run |
|---|---|
| `1.2.3.4` | `check "$IP"` (multi-provider summary) |
| `1.2.3.4 -f json` | `check "$IP" -f json` |
| `1.2.3.4 report` | `report "$IP"` (markdown report) |
| `1.2.3.4 --provider abuseipdb` | `check "$IP" --provider "$PROVIDER"` |
| `1.2.3.4 --no-cache` | `check "$IP" --no-cache` |
| `ips.txt` | `batch "$FILE"` |
| `ips.txt --dnsbl-overlap` | `batch "$FILE" --dnsbl-overlap` |
| _(no args)_ | Show help/usage |

Operational commands: `providers`, `cache-stats`, `cache-clear [--provider P] [--ip IP]`, `rate-limit-status`, `help`.

## Output contract

Expected structure:

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

Provider set: Spamhaus DNSBL, ProxyCheck.io, StopForumSpam, Blocklist.de, GreyNoise, AbuseIPDB, IPQualityScore, Scamalytics.

After returning results, offer next actions: full report, single-provider recheck, batch check, raw JSON, or cache-clear recheck.

## Related

- `tools/security/ip-reputation.md` — full documentation and provider reference
- `tools/security/tirith.md` — terminal security guard
- `tools/security/cdn-origin-ip.md` — CDN origin IP leak detection
- `/email-health-check` — email DNSBL and deliverability check
