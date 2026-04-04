---
description: Domain intelligence using THC and Reconeer APIs for DNS reconnaissance
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Domain Research - DNS Intelligence Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Domain reconnaissance via reverse DNS, subdomain enumeration, and CNAME discovery
- **Helper**: `~/.aidevops/agents/scripts/domain-research-helper.sh`
- **API Reference**: `seo/domain-research-api-reference.md` (endpoints, response formats, raw curl examples)

**Data Sources**:

| Provider | Free Tier | Paid Tier | Best For |
|----------|-----------|-----------|----------|
| **THC** (`ip.thc.org`) | 250 req (0.5/sec replenish) | N/A | rDNS, CNAMEs, bulk exports |
| **Reconeer** (`reconeer.com`) | 10 queries/day | $49/mo unlimited | Subdomain enum, IP lookups |

**Use THC** for bulk operations and CNAME discovery. **Use Reconeer** for enriched subdomain data with IP resolution.

**THC Commands**:

```bash
domain-research-helper.sh rdns 1.1.1.1                          # Reverse DNS (IP -> domains)
domain-research-helper.sh subdomains example.com                 # Subdomain enumeration
domain-research-helper.sh cnames github.io                       # CNAME lookup
domain-research-helper.sh rdns-block 1.1.1.0/24                 # IP block lookup
domain-research-helper.sh export-rdns 1.1.1.1 --output out.csv  # CSV export (up to 50K)
domain-research-helper.sh export-subdomains example.com --output subs.csv
domain-research-helper.sh export-cnames target.com --output cnames.csv
```

**Reconeer Commands**:

```bash
domain-research-helper.sh reconeer domain example.com           # Subdomains + IPs
domain-research-helper.sh reconeer ip 8.8.8.8                   # IP lookup
domain-research-helper.sh reconeer subdomain api.example.com    # Subdomain details
domain-research-helper.sh reconeer domain example.com --api-key YOUR_KEY
# Or set RECONEER_API_KEY in ~/.config/aidevops/credentials.sh
```

**Use Cases**: Attack surface discovery | Infrastructure mapping | Competitor analysis | Subdomain takeover detection | DNS migration planning | Security reconnaissance

<!-- AI-CONTEXT-END -->

## Operational Examples

```bash
# Attack surface discovery
domain-research-helper.sh rdns 203.0.113.50 --json > corp-domains.json
domain-research-helper.sh subdomains corp.com --all > corp-subs.txt
domain-research-helper.sh cnames corp.com --check-dangling

# Competitor analysis
domain-research-helper.sh rdns $(dig +short competitor.com) --json
domain-research-helper.sh subdomains competitor.com --all

# CDN/hosting analysis
domain-research-helper.sh cnames cdn.cloudflare.net --limit 100
domain-research-helper.sh cnames github.io --limit 100
domain-research-helper.sh cnames cname.vercel-dns.com --limit 100

# DNS migration planning
domain-research-helper.sh export-subdomains mydomain.com --output pre-migration.csv
# After migration:
domain-research-helper.sh subdomains mydomain.com > post-migration.txt
diff pre-migration.csv post-migration.txt
```

## Integration

```bash
# With site crawler
domain-research-helper.sh subdomains example.com --output subs.txt
while read sub; do site-crawler-helper.sh crawl "https://$sub" --depth 2; done < subs.txt

# With security scanning
domain-research-helper.sh rdns 1.2.3.4 --json | jq -r '.domains[]' | nuclei -l - -t cves/

# With DNS provider comparison
domain-research-helper.sh export-subdomains mydomain.com --output known-subs.csv
cloudflare-dns-helper.sh list-records mydomain.com --output cf-records.csv
diff known-subs.csv cf-records.csv
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| THC rate limited | Wait 8 minutes or use database download |
| Reconeer "limit exceeded" | Wait until next day or upgrade to premium |
| No results | Domain may not be in database; try alternative provider |
| Timeout | Reduce limit parameter or use pagination |
| IDN issues | Use `--raw` flag for punycode domains |

## Related Agents

- `seo/site-crawler.md` - Crawl discovered domains
- `services/hosting/dns-providers.md` - DNS management
- `services/hosting/cloudflare.md` - Cloudflare DNS integration
- `tools/browser/crawl4ai.md` - Web crawling
- `seo/google-search-console.md` - Search performance data
