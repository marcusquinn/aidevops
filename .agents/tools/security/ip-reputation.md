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

- **Helper**: `ip-reputation-helper.sh` | **Slash command**: `/ip-check <ip>`
- **Providers**: 11 (5 free/no-key, 6 free-tier with API key)
- **Output**: `table` (default), `json`, `markdown`, `compact`
- **Cache**: SQLite, per-provider TTL (1h–7d), auto-prune expired entries
- **Rate limits**: HTTP 429 detection with exponential backoff retry

<!-- AI-CONTEXT-END -->

## Commands

```bash
# Single IP check (table output)
ip-reputation-helper.sh check 1.2.3.4

# Output formats: json, markdown, compact
ip-reputation-helper.sh check 1.2.3.4 -f json
ip-reputation-helper.sh check 1.2.3.4 -f compact        # one-line, for scripting

# Detailed markdown report
ip-reputation-helper.sh report 1.2.3.4

# Batch check (one IP per line)
ip-reputation-helper.sh batch ips.txt
ip-reputation-helper.sh batch ips.txt --rate-limit 1 --dnsbl-overlap -f json

# Single provider only
ip-reputation-helper.sh check 1.2.3.4 --provider abuseipdb

# Cache and rate limit management
ip-reputation-helper.sh providers              # list all providers + status
ip-reputation-helper.sh cache-stats            # cache statistics
ip-reputation-helper.sh cache-clear --provider abuseipdb
ip-reputation-helper.sh cache-clear --ip 1.2.3.4
ip-reputation-helper.sh rate-limit-status      # per-provider rate limit status
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

**Table** (default) — colored terminal output with per-provider breakdown, cache hit/miss indicators:

```text
IP: 1.2.3.4 | Risk: CLEAN (2/100) | Providers: 8/10 | Cache: 5 hit, 3 miss
Tor: NO | Proxy: NO | VPN: NO

Provider           Risk    Score  Source  Details
Spamhaus DNSBL     clean   0      cached  clean
ProxyCheck.io      clean   0      live    clean
...
```

**JSON** (`-f json`) — structured output with `unified_score`, `risk_level`, `recommendation`, per-provider results, and `summary` (providers queried/responded/errored, is_tor/proxy/vpn, cache hits/misses).

**Compact** (`-f compact`) — one-line per IP: `1.2.3.4  CLEAN (2/100)  listed:0  flags:none`

**Markdown** (`report` or `-f markdown`) — full report with summary table, provider results table, cache statistics. Suitable for audit/compliance documentation.

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

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `IP_REP_TIMEOUT` | `15` | Per-provider timeout (seconds) |
| `IP_REP_FORMAT` | `table` | Default output format |
| `IP_REP_CACHE_DIR` | `~/.cache/ip-reputation` | SQLite cache directory |
| `IP_REP_CACHE_TTL` | `86400` | Default cache TTL (seconds) |
| `IP_REP_RATE_LIMIT` | `2` | Batch requests/second per provider |

## API Key Setup

Store keys via `aidevops secret set NAME` (never paste in conversation). Keys load automatically from `~/.config/aidevops/credentials.sh`.

```bash
# Required for keyed providers:
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

## Rate Limit Handling

Provider APIs enforce rate limits (e.g., AbuseIPDB 1000/day, VirusTotal 500/day). The helper handles this automatically: HTTP 429 detection → exponential backoff retry (2s, 4s, up to 2 retries) → cooldown tracking in SQLite (subsequent queries skip rate-limited providers until cooldown expires). Monitor with `rate-limit-status`.

## Caching

Results cached in SQLite (`~/.cache/ip-reputation/cache.db`) with per-provider TTLs: DNSBL (1h), proxy detectors (6h), abuse databases (24h), Shodan (7d). Auto-prune runs hourly. Output shows cache hit/miss counts. Bypass with `--no-cache`; manage with `cache-stats` and `cache-clear`.

## Scoring Algorithm

1. Each provider returns a score (0–100) and `is_listed` flag
2. Unified score = weighted average across responding providers
3. Boost applied if 2+ providers agree on listing (+10) or 3+ agree (+15)
4. Final risk level determined by unified score thresholds

## DNSBL Integration

The `--dnsbl-overlap` flag in batch mode cross-references results with the same DNSBL zones used by `email-health-check-helper.sh` (zen.spamhaus.org, bl.spamcop.net, b.barracudacentral.org). Useful when vetting IPs for email sending.

## Related

- `tools/security/tirith.md` — Terminal security guard
- `tools/security/shannon.md` — AI pentesting for web applications
- `tools/security/cdn-origin-ip.md` — CDN origin IP leak detection
- `services/email/email-health-check.md` — Email DNSBL and deliverability
- `/ip-check <ip>` — Slash command shortcut
