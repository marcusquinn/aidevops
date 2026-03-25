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

# Domain Research - DNS Intelligence Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Domain reconnaissance via reverse DNS, subdomain enumeration, and CNAME discovery
- **Helper**: `~/.aidevops/agents/scripts/domain-research-helper.sh`

**Data Sources**:

| Provider | Free Tier | Paid Tier | Best For |
|----------|-----------|-----------|----------|
| **THC** (`ip.thc.org`) | 250 req (0.5/sec replenish) | N/A | rDNS, CNAMEs, bulk exports |
| **Reconeer** (`reconeer.com`) | 10 queries/day | $49/mo unlimited | Subdomain enum, IP lookups |

**Use THC** for bulk operations and CNAME discovery. **Use Reconeer** for enriched subdomain data with IP resolution.

**THC Commands**:

```bash
domain-research-helper.sh rdns 1.1.1.1                          # Reverse DNS (IP → domains)
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

**Use Cases**: Attack surface discovery · Infrastructure mapping · Competitor analysis · Subdomain takeover detection · DNS migration planning · Security reconnaissance

<!-- AI-CONTEXT-END -->

## THC API

**4.51 billion records.** Rate limit: 250 requests, 0.5/sec replenish (~8 min full recovery). Helper handles backoff automatically.

### Simple CLI Endpoints

| Endpoint | Purpose | Example |
|----------|---------|---------|
| `/{ip}` | Reverse DNS | `curl https://ip.thc.org/1.1.1.1` |
| `/me` | Your IP's rDNS | `curl https://ip.thc.org/me` |
| `/sb/{domain}` | Subdomain lookup | `curl https://ip.thc.org/sb/wikipedia.org` |
| `/cn/{domain}` | CNAME lookup | `curl https://ip.thc.org/cn/github.io` |

Query params: `f=example.com` (filter by apex) · `l=50` (limit, max 100) · `nocolor=1` · `raw=1` · `noheader=1`

### JSON API Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/v1/lookup` | POST | Filtered rDNS with pagination |
| `/api/v1/lookup/subdomains` | POST | Subdomain lookup with pagination |
| `/api/v1/lookup/cnames` | POST | CNAME lookup with pagination |
| `/api/v1/download` | GET | CSV export for rDNS (max 50,000) |
| `/api/v1/subdomains/download` | GET | CSV export for subdomains |
| `/api/v1/cnames/download` | GET | CSV export for CNAMEs |

### JSON API Examples

```bash
# Paginated reverse DNS
curl https://ip.thc.org/api/v1/lookup -X POST \
  -d '{"ip_address":"1.1.1.1", "limit": 10}' -s | jq

# With TLD filter
curl https://ip.thc.org/api/v1/lookup -X POST \
  -d '{"ip_address":"1.1.1.1", "limit": 10, "tld":["com","org"]}' -s | jq

# Next page (use page_state from previous response)
curl https://ip.thc.org/api/v1/lookup -X POST \
  -d '{"ip_address":"1.1.1.1", "limit": 10, "page_state":"..."}' -s | jq

# Subdomain lookup
curl https://ip.thc.org/api/v1/lookup/subdomains -X POST \
  -d '{"domain":"github.com", "limit": 10}' -s | jq

# CNAME lookup with apex filter
curl https://ip.thc.org/api/v1/lookup/cnames -X POST \
  -d '{"target_domain":"google.com", "apex_domain":"example.com", "limit": 10}' -s | jq
```

### CSV Exports

```bash
curl 'https://ip.thc.org/api/v1/download?ip_address=1.1.1.1&limit=500' -o rdns.csv
curl 'https://ip.thc.org/api/v1/subdomains/download?domain=thc.org&limit=500' -o subs.csv
curl 'https://ip.thc.org/api/v1/cnames/download?target_domain=google.com&limit=500' -o cnames.csv
curl 'https://ip.thc.org/api/v1/download?ip_address=1.1.1.1&hide_header=true' -o rdns.csv
```

### Database Downloads (Offline Analysis)

```bash
curl -O https://dns.team-teso.net/2025/rdns-oct.parquet.gz  # Parquet (recommended for DuckDB)
curl -O https://dns.team-teso.net/2025/rdns-oct.csv.gz      # CSV

duckdb -c "SELECT * FROM 'rdns-oct.parquet' WHERE ip_address='1.1.1.1' LIMIT 10"
zcat rdns-oct.csv.gz | grep -m 10 'example.com'
```

### Response Headers

`ASN` · `Org` · `City` · `Country` · `GPS` · `Entries` (results/total) · `Rate Limit` (remaining + replenish rate)

### Output Formats

```text
;ASN    : 13335
;Org    : Cloudflare, Inc.
;;Entries: 50/1234

one.one.one.one
cloudflare-dns.com
```

```json
{
  "meta": {"asn": 13335, "org": "Cloudflare, Inc.", "total_entries": 1234, "returned_entries": 50},
  "domains": ["one.one.one.one", "cloudflare-dns.com"],
  "page_state": "..."
}
```

```csv
domain,ip_address,first_seen,last_seen
one.one.one.one,1.1.1.1,2018-04-01,2025-01-15
```

---

## Reconeer API

Curated subdomain enumeration with enriched data (IP addresses, metadata).

| Endpoint | Purpose |
|----------|---------|
| `/api/domain/:domain` | Subdomains, IPs, counts |
| `/api/ip/:ip` | Hostnames for an IP |
| `/api/subdomain/:subdomain` | Details for specific subdomain |

**Auth**: Free tier = 10 queries/day, no key. Premium = $49/mo unlimited, requires `RECONEER_API_KEY`.

```bash
domain-research-helper.sh reconeer domain github.com
domain-research-helper.sh reconeer ip 140.82.121.4
domain-research-helper.sh reconeer subdomain api.github.com
domain-research-helper.sh reconeer domain example.com --json
```

**Response format**:

```json
{
  "domain": "example.com",
  "subdomains": [
    {"name": "www.example.com", "ip": "93.184.216.34"},
    {"name": "api.example.com", "ip": "93.184.216.35"}
  ],
  "count": 2
}
```

**CLI tool** (alternative):

```bash
go install -v github.com/reconeer/reconeer/cmd/reconeer@latest
reconeer -d example.com
reconeer -dL domains.txt -o results.txt
```

---

## Use Cases

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
