---
description: Check IP reputation across multiple providers — vet VPS/server/proxy IPs before purchase or deployment
agent: Build+
mode: subagent
---

Check IP reputation and risk level across multiple providers.

Arguments: $ARGUMENTS

## Workflow

### Step 1: Parse Arguments

Parse `$ARGUMENTS` to determine the check type:

- **IP only** (e.g., `1.2.3.4`): Full multi-provider check, table output
- **IP + format** (e.g., `1.2.3.4 -f json`): Check with specified output format
- **IP + report** (e.g., `1.2.3.4 report`): Generate detailed markdown report
- **IP + provider** (e.g., `1.2.3.4 --provider abuseipdb`): Single-provider check
- **File** (e.g., `ips.txt`): Batch check from file
- **No args**: Show usage

### Step 2: Run the Check

```bash
# Full check (default table output)
~/.aidevops/agents/scripts/ip-reputation-helper.sh check "$IP"

# JSON output
~/.aidevops/agents/scripts/ip-reputation-helper.sh check "$IP" -f json

# Markdown report
~/.aidevops/agents/scripts/ip-reputation-helper.sh report "$IP"

# Single provider
~/.aidevops/agents/scripts/ip-reputation-helper.sh check "$IP" --provider "$PROVIDER"

# Batch from file
~/.aidevops/agents/scripts/ip-reputation-helper.sh batch "$FILE"
```

### Step 3: Present Results

Summarize the output clearly:

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

### Step 4: Offer Follow-up Actions

```text
Actions:
1. Generate full markdown report
2. Check with a specific provider
3. Batch check a list of IPs
4. Show raw JSON output
5. Clear cache and re-check
```

## Options

| Command | Purpose |
|---------|---------|
| `/ip-check 1.2.3.4` | Full multi-provider check |
| `/ip-check 1.2.3.4 -f json` | JSON output |
| `/ip-check 1.2.3.4 report` | Detailed markdown report |
| `/ip-check 1.2.3.4 --provider abuseipdb` | Single provider |
| `/ip-check 1.2.3.4 --no-cache` | Bypass cache |
| `/ip-check ips.txt` | Batch check from file |
| `/ip-check ips.txt --dnsbl-overlap` | Batch with DNSBL cross-reference |

## Examples

**Clean IP:**

```text
User: /ip-check 8.8.8.8
AI: Checking IP reputation for 8.8.8.8...

    IP Reputation: 8.8.8.8
    Risk Level:  CLEAN (score: 0/100)
    Verdict:     SAFE — no significant flags detected

    Providers (8/10 responded):
      Spamhaus DNSBL    clean   (0)
      ProxyCheck.io     clean   (0)
      ...

    Flags: Tor=NO  Proxy=NO  VPN=NO
```

**Flagged IP:**

```text
User: /ip-check 185.220.101.1
AI: Checking IP reputation for 185.220.101.1...

    IP Reputation: 185.220.101.1
    Risk Level:  CRITICAL (score: 92/100)
    Verdict:     AVOID — IP is heavily flagged across multiple sources

    Providers (9/10 responded):
      Spamhaus DNSBL    critical  (100)  listed
      AbuseIPDB         critical  (98)   listed
      GreyNoise         high      (85)   listed
      ...

    Flags: Tor=YES  Proxy=YES  VPN=NO
    Listed by: 7 provider(s)
```

**JSON output:**

```text
User: /ip-check 1.2.3.4 -f json
AI: {
      "ip": "1.2.3.4",
      "scan_time": "2026-02-19T12:00:00Z",
      "unified_score": 2,
      "risk_level": "clean",
      "recommendation": "SAFE — no significant flags detected",
      ...
    }
```

**Markdown report:**

```text
User: /ip-check 1.2.3.4 report
AI: # IP Reputation Report: 1.2.3.4

    - **Scanned**: 2026-02-19T12:00:00Z
    - **Risk Level**: CLEAN (2/100)
    - **Verdict**: SAFE — no significant flags detected

    ## Summary
    | Metric | Value |
    ...
```

## Related

- `tools/security/ip-reputation.md` — Full documentation and provider reference
- `tools/security/tirith.md` — Terminal security guard
- `tools/security/cdn-origin-ip.md` — CDN origin IP leak detection
- `/email-health-check` — Email DNSBL and deliverability check
