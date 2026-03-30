---
description: Check IP reputation across multiple providers — vet VPS/server/proxy IPs before purchase or deployment
agent: Build+
mode: subagent
---

Check IP reputation and risk level across multiple providers.

Arguments: $ARGUMENTS

## Argument Dispatch

| Input | Action |
|-------|--------|
| `1.2.3.4` | Full multi-provider check, table output |
| `1.2.3.4 -f json` | JSON output |
| `1.2.3.4 report` | Detailed markdown report |
| `1.2.3.4 --provider abuseipdb` | Single-provider check |
| `ips.txt` | Batch check from file |
| `ips.txt --dnsbl-overlap` | Batch with DNSBL cross-reference |
| `1.2.3.4 --no-cache` | Bypass cache |
| _(no args)_ | Show usage |

## Commands

```bash
~/.aidevops/agents/scripts/ip-reputation-helper.sh check "$IP"
~/.aidevops/agents/scripts/ip-reputation-helper.sh check "$IP" -f json
~/.aidevops/agents/scripts/ip-reputation-helper.sh report "$IP"
~/.aidevops/agents/scripts/ip-reputation-helper.sh check "$IP" --provider "$PROVIDER"
~/.aidevops/agents/scripts/ip-reputation-helper.sh batch "$FILE"
```

## Output Format

```text
IP Reputation: 1.2.3.4

Risk Level:  CLEAN (score: 2/100)
Verdict:     SAFE — no significant flags detected

Providers (8/10 responded):
  Spamhaus DNSBL    clean   (0)
  ProxyCheck.io     clean   (0)
  StopForumSpam     clean   (0)
  Blocklist.de      clean   (0)
  GreyNoise         clean   (0)
  AbuseIPDB         clean   (0)
  IPQualityScore    clean   (2)
  Scamalytics       clean   (0)

Flags: Tor=NO  Proxy=NO  VPN=NO
```

After presenting results, offer follow-up: full report, single-provider recheck, batch check, raw JSON, cache-clear recheck.

## Related

- `tools/security/ip-reputation.md` — full documentation and provider reference
- `tools/security/tirith.md` — terminal security guard
- `tools/security/cdn-origin-ip.md` — CDN origin IP leak detection
- `/email-health-check` — email DNSBL and deliverability check
