---
description: IP reputation checker — multi-provider risk scoring for VPS/server/proxy IPs before purchase or deployment
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
---

# IP Reputation Checker

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Vet VPS/server/proxy IPs before purchase or deployment — check if they are burned (blacklisted, flagged)
- **Helper**: `ip-reputation-helper.sh`
- **Slash command**: `/ip-check <ip>`
- **Providers**: 11 providers (5 free/no-key, 6 free-tier with API key)
- **Output formats**: `table` (default), `json`, `markdown`, `compact`
- **Cache**: SQLite, per-provider TTL (1h–7d), auto-prune expired entries
- **Rate limits**: HTTP 429 detection with exponential backoff retry

<!-- AI-CONTEXT-END -->

## Use Cases

- Vet a VPS IP before purchasing a server
- Check if a proxy/VPN IP is burned before use
- Batch-screen a list of IPs for deployment
- Generate a markdown report for audit/compliance
- Cross-reference with email DNSBL blacklists

## Commands

```bash
# Check a single IP (table output)
ip-reputation-helper.sh check 1.2.3.4

# Check with JSON output
ip-reputation-helper.sh check 1.2.3.4 -f json

# Check with markdown report output
ip-reputation-helper.sh check 1.2.3.4 --format markdown

# Generate detailed markdown report
ip-reputation-helper.sh report 1.2.3.4

# Batch check from file (one IP per line)
ip-reputation-helper.sh batch ips.txt

# Batch with rate limiting and DNSBL overlap
ip-reputation-helper.sh batch ips.txt --rate-limit 1 --dnsbl-overlap

# Batch with JSON output
ip-reputation-helper.sh batch ips.txt -f json

# Use a single provider only
ip-reputation-helper.sh check 1.2.3.4 --provider abuseipdb

# Compact one-line output (for scripting)
ip-reputation-helper.sh check 1.2.3.4 --format compact

# Disable color output
ip-reputation-helper.sh check 1.2.3.4 --no-color

# Bypass cache for fresh results
ip-reputation-helper.sh check 1.2.3.4 --no-cache

# List all providers and their status
ip-reputation-helper.sh providers

# Show cache statistics
ip-reputation-helper.sh cache-stats

# Clear cache for a provider
ip-reputation-helper.sh cache-clear --provider abuseipdb

# Clear cache for a specific IP
ip-reputation-helper.sh cache-clear --ip 1.2.3.4

# Show rate limit status per provider
ip-reputation-helper.sh rate-limit-status

# Show help
ip-reputation-helper.sh help
```

## Subcommand Help

```bash
# Per-subcommand help (--help flag)
ip-reputation-helper.sh check --help
ip-reputation-helper.sh batch --help
ip-reputation-helper.sh report --help
ip-reputation-helper.sh cache-clear --help
```

## Providers

### Free / No API Key Required

| Provider | What it checks | Cache TTL |
|----------|---------------|-----------|
| `spamhaus` | Spamhaus DNSBL (SBL/XBL/PBL) via DNS | 1h |
| `proxycheck` | Proxy/VPN/Tor detection (ProxyCheck.io) | 6h |
| `stopforumspam` | Forum spammer database | 1h |
| `blocklistde` | Attack/botnet IPs (Blocklist.de) | 1h |
| `greynoise` | Internet noise scanner (Community API) | 24h |

### Free Tier with API Key

| Provider | What it checks | Free Limit | Cache TTL |
|----------|---------------|------------|-----------|
| `abuseipdb` | Community abuse reports | 1,000/day | 24h |
| `virustotal` | 70+ AV engine IP analysis | 500/day | 24h |
| `ipqualityscore` | Fraud/proxy/VPN detection | 5,000/month | 24h |
| `scamalytics` | Fraud scoring | 5,000/month | 24h |
| `shodan` | Open ports, vulns, tags | Free key, limited credits | 7d |
| `iphub` | Proxy/VPN/hosting detection | 1,000/day | 6h |

## Risk Levels

| Level | Score | Meaning |
|-------|-------|---------|
| `clean` | 0–4 | No significant flags |
| `low` | 5–24 | Minor flags detected |
| `medium` | 25–49 | Some flags, investigate before use |
| `high` | 50–74 | Significant abuse/attack history |
| `critical` | 75–100 | Heavily flagged across multiple sources |

## Output Formats

### Table (default)

Terminal-friendly colored output with per-provider breakdown, including cache hit/miss
indicators and source column (cached vs live):

```text
=== IP Reputation Report ===
IP:          1.2.3.4
Scanned:     2026-02-19T12:00:00Z
Risk Level:  CLEAN (score: 2/100)
Verdict:     SAFE — no significant flags detected

Summary:
  Providers:  8/10 responded
  Listed by:  0 provider(s)
  Cache:      5 hit(s), 3 miss(es)
  Tor:        NO
  Proxy:      NO
  VPN:        NO

Provider Results:
  Provider           Risk       Score    Source   Details
  --------           ----       -----    ------   -------
  Spamhaus DNSBL     clean      0        cached   clean
  ProxyCheck.io      clean      0        live     clean
  ...
```

### JSON (`-f json`)

Machine-readable structured output with cache statistics:

```json
{
  "ip": "1.2.3.4",
  "scan_time": "2026-02-19T12:00:00Z",
  "unified_score": 2,
  "risk_level": "clean",
  "recommendation": "SAFE — no significant flags detected",
  "summary": {
    "providers_queried": 10,
    "providers_responded": 8,
    "providers_errored": 2,
    "listed_by": 0,
    "is_tor": false,
    "is_proxy": false,
    "is_vpn": false,
    "cache_hits": 5,
    "cache_misses": 3
  },
  "providers": [...]
}
```

### Compact (`-f compact`)

One-line summary per IP, suitable for scripting and batch pipelines:

```text
1.2.3.4  CLEAN (2/100)  listed:0  flags:none
```

### Markdown (`report` subcommand or `--format markdown`)

Full markdown report suitable for documentation or audit, includes cache statistics
and source column:

```markdown
# IP Reputation Report: 1.2.3.4

- **Scanned**: 2026-02-19T12:00:00Z
- **Risk Level**: CLEAN (2/100)
- **Verdict**: SAFE — no significant flags detected

## Summary

| Metric | Value |
|--------|-------|
| Providers queried | 10 |
| Cache hits | 5 |
| Cache misses | 3 |
...

## Provider Results

| Provider | Risk Level | Score | Source | Listed | Details |
|----------|-----------|-------|--------|--------|---------|
...
```

## API Key Setup

Store keys via `aidevops secret set NAME` (never paste in conversation):

```bash
aidevops secret set ABUSEIPDB_API_KEY
aidevops secret set VIRUSTOTAL_API_KEY
aidevops secret set IPQUALITYSCORE_API_KEY
aidevops secret set SCAMALYTICS_API_KEY
aidevops secret set SHODAN_API_KEY
aidevops secret set IPHUB_API_KEY
# Optional (increases rate limits):
aidevops secret set PROXYCHECK_API_KEY
aidevops secret set GREYNOISE_API_KEY
```

Keys are loaded automatically from `~/.config/aidevops/credentials.sh`.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `IP_REP_TIMEOUT` | `15` | Per-provider timeout (seconds) |
| `IP_REP_FORMAT` | `table` | Default output format |
| `IP_REP_CACHE_DIR` | `~/.cache/ip-reputation` | SQLite cache directory |
| `IP_REP_CACHE_TTL` | `86400` | Default cache TTL (seconds) |
| `IP_REP_RATE_LIMIT` | `2` | Batch requests/second per provider |

## Options Reference

| Option | Short | Description |
|--------|-------|-------------|
| `--provider <p>` | `-p` | Use only specified provider |
| `--timeout <s>` | `-t` | Per-provider timeout in seconds |
| `--format <fmt>` | `-f` | Output format: `table`, `json`, `markdown`, `compact` |
| `--parallel` | | Run providers in parallel (default) |
| `--sequential` | | Run providers sequentially |
| `--no-cache` | | Bypass cache for this query |
| `--no-color` | | Disable color output (also respects `NO_COLOR` env) |
| `--rate-limit <n>` | | Batch requests/second (default: 2) |
| `--dnsbl-overlap` | | Cross-reference with email DNSBL in batch mode |

## Integration with Email Health Check

The `--dnsbl-overlap` flag in batch mode cross-references results with the same
DNSBL zones used by `email-health-check-helper.sh` (zen.spamhaus.org, bl.spamcop.net,
b.barracudacentral.org). Useful when vetting IPs for email sending.

## Rate Limit Handling

Provider APIs enforce rate limits (e.g., AbuseIPDB 1000/day, VirusTotal 500/day).
The helper handles this automatically:

1. **HTTP 429 detection**: Provider scripts capture HTTP status codes and return
   structured `rate_limited` errors with `retry_after` hints
2. **Exponential backoff**: On 429, the helper retries up to 2 times with
   exponential backoff (2s, 4s)
3. **Cooldown tracking**: Rate-limited providers are recorded in SQLite with
   their cooldown period; subsequent queries skip them until the cooldown expires
4. **Status monitoring**: `rate-limit-status` command shows per-provider rate
   limit history, hit counts, and current cooldown status

```bash
# Check which providers are currently rate-limited
ip-reputation-helper.sh rate-limit-status
```

## Caching

Results are cached in SQLite (`~/.cache/ip-reputation/cache.db`) with per-provider
TTLs. Cache features:

- **Auto-prune**: Expired entries are automatically cleaned up once per hour
- **Hit/miss tracking**: Output shows how many results came from cache vs live queries
- **Per-provider TTL**: DNSBL providers (1h), proxy detectors (6h), abuse databases (24h),
  Shodan (7d)
- **Bypass**: Use `--no-cache` to force fresh queries
- **Management**: `cache-stats` shows statistics, `cache-clear` removes entries

## Scoring Algorithm

1. Each provider returns a score (0–100) and `is_listed` flag
2. Unified score = weighted average across responding providers
3. Boost applied if 2+ providers agree on listing (+10) or 3+ agree (+15)
4. Final risk level determined by unified score thresholds

## Related

- `tools/security/tirith.md` — Terminal security guard
- `tools/security/shannon.md` — AI pentesting for web applications
- `tools/security/cdn-origin-ip.md` — CDN origin IP leak detection
- `services/email/email-health-check.md` — Email DNSBL and deliverability
- `/ip-check <ip>` — Slash command shortcut
