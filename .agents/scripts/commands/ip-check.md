---
description: Check IP reputation across multiple providers — vet VPS/server/proxy IPs before purchase or deployment
agent: Build+
mode: subagent
---

Arguments: $ARGUMENTS

## Argument Dispatch

| Input | Action | Command |
|-------|--------|---------|
| `1.2.3.4` | Full multi-provider check, table output | `ip-reputation-helper.sh check "$IP"` |
| `1.2.3.4 -f json` | JSON output | `ip-reputation-helper.sh check "$IP" -f json` |
| `1.2.3.4 report` | Detailed markdown report | `ip-reputation-helper.sh report "$IP"` |
| `1.2.3.4 --provider abuseipdb` | Single-provider check | `ip-reputation-helper.sh check "$IP" --provider "$PROVIDER"` |
| `ips.txt` | Batch check from file | `ip-reputation-helper.sh batch "$FILE"` |
| `ips.txt --dnsbl-overlap` | Batch with DNSBL cross-reference | `ip-reputation-helper.sh batch "$FILE" --dnsbl-overlap` |
| `1.2.3.4 --no-cache` | Bypass cache | `ip-reputation-helper.sh check "$IP" --no-cache` |
| _(no args)_ | Show usage | |

All commands: `~/.aidevops/agents/scripts/ip-reputation-helper.sh`

## Output Format

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

Providers: Spamhaus DNSBL, ProxyCheck.io, StopForumSpam, Blocklist.de, GreyNoise, AbuseIPDB, IPQualityScore, Scamalytics.

After presenting results, offer follow-up: full report, single-provider recheck, batch check, raw JSON, cache-clear recheck.

## Related

- `tools/security/ip-reputation.md` — full documentation and provider reference
- `tools/security/tirith.md` — terminal security guard
- `tools/security/cdn-origin-ip.md` — CDN origin IP leak detection
- `/email-health-check` — email DNSBL and deliverability check
