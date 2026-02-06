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

**Quick Commands (THC - default)**:

```bash
# Reverse DNS lookup (IP to domains)
domain-research-helper.sh rdns 1.1.1.1

# Subdomain enumeration
domain-research-helper.sh subdomains example.com

# CNAME lookup (find domains pointing to target)
domain-research-helper.sh cnames github.io

# IP block lookup (/24, /16, /8)
domain-research-helper.sh rdns-block 1.1.1.0/24

# CSV exports (up to 50,000 records)
domain-research-helper.sh export-rdns 1.1.1.1 --output results.csv
domain-research-helper.sh export-subdomains example.com --output subs.csv
domain-research-helper.sh export-cnames target.com --output cnames.csv
```

**Quick Commands (Reconeer)**:

```bash
# Subdomain enumeration (free: 10/day)
domain-research-helper.sh reconeer domain example.com

# IP lookup
domain-research-helper.sh reconeer ip 8.8.8.8

# Subdomain details
domain-research-helper.sh reconeer subdomain api.example.com

# With API key for unlimited access
domain-research-helper.sh reconeer domain example.com --api-key YOUR_KEY
# Or set RECONEER_API_KEY in ~/.config/aidevops/credentials.sh
```

**Use Cases**:

- Attack surface discovery
- Infrastructure mapping
- Competitor analysis
- Subdomain takeover detection
- DNS migration planning
- Security reconnaissance

<!-- AI-CONTEXT-END -->

## Overview

The Domain Research agent provides DNS intelligence capabilities using two complementary APIs:

1. **THC IP Database** (`ip.thc.org`) - 4.51 billion records, best for rDNS, CNAMEs, bulk exports
2. **Reconeer** (`reconeer.com`) - Curated subdomain enumeration with enriched data

### Capabilities by Provider

| Feature | THC | Reconeer |
|---------|-----|----------|
| Reverse DNS (IP → domains) | Yes | Yes |
| Subdomain enumeration | Yes | Yes (enriched) |
| CNAME discovery | Yes | No |
| IP block scanning | Yes | No |
| Bulk CSV export | Yes (50K) | No |
| Database download | Yes | No |
| Free tier | 250 req | 10 queries/day |
| Paid tier | N/A | $49/mo unlimited |

**Recommendation**: Use THC for bulk operations and CNAME discovery. Use Reconeer for enriched subdomain data with IP resolution.

## API Endpoints

### Simple CLI-Friendly Endpoints

| Endpoint | Purpose | Example |
|----------|---------|---------|
| `/{ip}` | Reverse DNS lookup | `curl https://ip.thc.org/1.1.1.1` |
| `/me` | Your current IP's rDNS | `curl https://ip.thc.org/me` |
| `/sb/{domain}` | Subdomain lookup | `curl https://ip.thc.org/sb/wikipedia.org` |
| `/cn/{domain}` | CNAME lookup | `curl https://ip.thc.org/cn/github.io` |

### Query Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `f` | Filter by apex domain | `?f=example.com` |
| `l` | Limit results (max 100) | `?l=50` |
| `nocolor` | Disable ANSI colors | `?nocolor=1` |
| `raw` | Disable IDN/punycode parsing | `?raw=1` |
| `noheader` | Hide response headers | `?noheader=1` |

### JSON API Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/v1/lookup` | POST | Filtered rDNS lookup with pagination |
| `/api/v1/lookup/subdomains` | POST | Subdomain lookup with pagination |
| `/api/v1/lookup/cnames` | POST | CNAME lookup with pagination |
| `/api/v1/download` | GET | CSV export for rDNS (max 50,000) |
| `/api/v1/subdomains/download` | GET | CSV export for subdomains |
| `/api/v1/cnames/download` | GET | CSV export for CNAMEs |

## Usage

### Reverse DNS Lookup

Find all domains hosted on an IP address:

```bash
# Simple lookup
domain-research-helper.sh rdns 1.1.1.1

# With domain filter
domain-research-helper.sh rdns 1.1.1.1 --filter cloudflare.com

# Limit results
domain-research-helper.sh rdns 1.1.1.1 --limit 50

# JSON output
domain-research-helper.sh rdns 1.1.1.1 --json
```

### IP Block Lookup

Scan entire IP ranges:

```bash
# /24 block (256 IPs)
domain-research-helper.sh rdns-block 192.168.1.0/24

# /16 block (65,536 IPs)
domain-research-helper.sh rdns-block 10.0.0.0/16 --limit 100

# Filter by TLD
domain-research-helper.sh rdns-block 1.1.1.0/24 --tld com,org
```

### Subdomain Enumeration

Discover all known subdomains:

```bash
# Basic enumeration
domain-research-helper.sh subdomains github.com

# With pagination
domain-research-helper.sh subdomains github.com --all

# Export to CSV
domain-research-helper.sh export-subdomains github.com --output github-subs.csv
```

### CNAME Discovery

Find domains pointing to a target (useful for CDN analysis, subdomain takeover):

```bash
# Find all domains using GitHub Pages
domain-research-helper.sh cnames github.io

# Find domains using Cloudflare
domain-research-helper.sh cnames cdn.cloudflare.net

# Filter by apex domain
domain-research-helper.sh cnames github.io --filter example.com
```

## JSON API Examples

### Paginated Reverse DNS

```bash
# First page
curl https://ip.thc.org/api/v1/lookup -X POST \
  -d '{"ip_address":"1.1.1.1", "limit": 10}' -s | jq

# With TLD filter
curl https://ip.thc.org/api/v1/lookup -X POST \
  -d '{"ip_address":"1.1.1.1", "limit": 10, "tld":["com","org"]}' -s | jq

# Next page (use page_state from previous response)
curl https://ip.thc.org/api/v1/lookup -X POST \
  -d '{"ip_address":"1.1.1.1", "limit": 10, "page_state":"..."}' -s | jq
```

### Paginated Subdomain Lookup

```bash
curl https://ip.thc.org/api/v1/lookup/subdomains -X POST \
  -d '{"domain":"github.com", "limit": 10}' -s | jq
```

### Paginated CNAME Lookup

```bash
curl https://ip.thc.org/api/v1/lookup/cnames -X POST \
  -d '{"target_domain":"google.com", "limit": 10}' -s | jq

# Filter by apex domain
curl https://ip.thc.org/api/v1/lookup/cnames -X POST \
  -d '{"target_domain":"google.com", "apex_domain":"example.com", "limit": 10}' -s | jq
```

## CSV Exports

Export large datasets (up to 50,000 records):

```bash
# Reverse DNS export
curl 'https://ip.thc.org/api/v1/download?ip_address=1.1.1.1&limit=500' -o rdns.csv

# Subdomain export
curl 'https://ip.thc.org/api/v1/subdomains/download?domain=thc.org&limit=500' -o subs.csv

# CNAME export
curl 'https://ip.thc.org/api/v1/cnames/download?target_domain=google.com&limit=500' -o cnames.csv

# Hide CSV headers
curl 'https://ip.thc.org/api/v1/download?ip_address=1.1.1.1&hide_header=true' -o rdns.csv
```

## Database Downloads

For offline analysis, monthly database dumps are available:

```bash
# Download Parquet format (recommended for DuckDB)
curl -O https://dns.team-teso.net/2025/rdns-oct.parquet.gz

# Download CSV format
curl -O https://dns.team-teso.net/2025/rdns-oct.csv.gz

# Query with DuckDB
duckdb -c "SELECT * FROM 'rdns-oct.parquet' WHERE ip_address='1.1.1.1' LIMIT 10"

# Grep through CSV
zcat rdns-oct.csv.gz | grep -m 10 'example.com'
```

## Use Cases

### Attack Surface Discovery

Map all domains associated with an organization:

```bash
# Find domains on known IPs
domain-research-helper.sh rdns 203.0.113.50 --json > corp-domains.json

# Enumerate subdomains
domain-research-helper.sh subdomains corp.com --all > corp-subs.txt

# Check for dangling CNAMEs (subdomain takeover)
domain-research-helper.sh cnames corp.com --check-dangling
```

### Competitor Analysis

Discover competitor infrastructure:

```bash
# Find all domains on competitor's IP
domain-research-helper.sh rdns $(dig +short competitor.com) --json

# Find their subdomains
domain-research-helper.sh subdomains competitor.com --all
```

### CDN/Hosting Analysis

Find all domains using a specific service:

```bash
# Domains using Cloudflare
domain-research-helper.sh cnames cdn.cloudflare.net --limit 100

# Domains using GitHub Pages
domain-research-helper.sh cnames github.io --limit 100

# Domains using Vercel
domain-research-helper.sh cnames cname.vercel-dns.com --limit 100
```

### DNS Migration Planning

Before migrating DNS:

```bash
# Export all current records
domain-research-helper.sh export-subdomains mydomain.com --output pre-migration.csv

# After migration, compare
domain-research-helper.sh subdomains mydomain.com > post-migration.txt
diff pre-migration.csv post-migration.txt
```

## Response Headers

The API returns useful metadata in response headers:

| Header | Description |
|--------|-------------|
| `ASN` | Autonomous System Number |
| `Org` | Organization name |
| `City` | Geographic city |
| `Country` | Geographic country |
| `GPS` | Latitude/longitude coordinates |
| `Entries` | Number of results / total available |
| `Rate Limit` | Remaining requests and replenish rate |

## Rate Limiting

- **Limit**: 250 requests
- **Replenish**: 0.50 requests/second
- **Recovery**: Full limit restored in ~8 minutes

The helper script automatically handles rate limiting with exponential backoff.

## Integration with Other Agents

### With Site Crawler

```bash
# Discover subdomains, then crawl each
domain-research-helper.sh subdomains example.com --output subs.txt
while read sub; do
  site-crawler-helper.sh crawl "https://$sub" --depth 2
done < subs.txt
```

### With Security Scanning

```bash
# Find all domains on IP, check for vulnerabilities
domain-research-helper.sh rdns 1.2.3.4 --json | \
  jq -r '.domains[]' | \
  nuclei -l - -t cves/
```

### With DNS Providers

Cross-reference with your DNS provider:

```bash
# Export known subdomains
domain-research-helper.sh export-subdomains mydomain.com --output known-subs.csv

# Compare with Cloudflare DNS records
cloudflare-dns-helper.sh list-records mydomain.com --output cf-records.csv
diff known-subs.csv cf-records.csv
```

## Output Formats

### CLI Output (Default)

```text
;ASN    : 13335
;Org    : Cloudflare, Inc.
;City   : San Francisco
;Country: United States
;GPS    : 37.7749,-122.4194
;;Entries: 50/1234

one.one.one.one
cloudflare-dns.com
1dot1dot1dot1.cloudflare-dns.com
```

### JSON Output

```json
{
  "meta": {
    "asn": 13335,
    "org": "Cloudflare, Inc.",
    "city": "San Francisco",
    "country": "United States",
    "gps": "37.7749,-122.4194",
    "total_entries": 1234,
    "returned_entries": 50
  },
  "domains": [
    "one.one.one.one",
    "cloudflare-dns.com",
    "1dot1dot1dot1.cloudflare-dns.com"
  ],
  "page_state": "..."
}
```

### CSV Output

```csv
domain,ip_address,first_seen,last_seen
one.one.one.one,1.1.1.1,2018-04-01,2025-01-15
cloudflare-dns.com,1.1.1.1,2018-04-01,2025-01-15
```

---

## Reconeer API

Reconeer provides curated subdomain enumeration with enriched data including IP addresses and metadata.

### API Endpoints

| Endpoint | Purpose | Example |
|----------|---------|---------|
| `/api/domain/:domain` | Subdomains, IPs, counts | `curl https://reconeer.com/api/domain/example.com` |
| `/api/ip/:ip` | Hostnames for an IP | `curl https://reconeer.com/api/ip/8.8.8.8` |
| `/api/subdomain/:subdomain` | Details for specific subdomain | `curl https://reconeer.com/api/subdomain/api.example.com` |

### Authentication

- **Free tier**: 10 queries/day, no API key required
- **Premium**: $49/mo for unlimited queries, requires API key

Store your API key in `~/.config/aidevops/credentials.sh`:

```bash
export RECONEER_API_KEY="your-api-key-here"
```

### Usage Examples

```bash
# Domain reconnaissance (subdomains + IPs)
domain-research-helper.sh reconeer domain github.com

# IP lookup (find hostnames)
domain-research-helper.sh reconeer ip 140.82.121.4

# Specific subdomain details
domain-research-helper.sh reconeer subdomain api.github.com

# With explicit API key
domain-research-helper.sh reconeer domain example.com --api-key YOUR_KEY

# JSON output
domain-research-helper.sh reconeer domain example.com --json
```

### Response Format

Domain lookup returns:

```json
{
  "domain": "example.com",
  "subdomains": [
    {"name": "www.example.com", "ip": "93.184.216.34"},
    {"name": "api.example.com", "ip": "93.184.216.35"},
    {"name": "mail.example.com", "ip": "93.184.216.36"}
  ],
  "count": 3
}
```

### CLI Tool (Alternative)

Reconeer also provides a Go CLI tool for advanced usage:

```bash
# Install
go install -v github.com/reconeer/reconeer/cmd/reconeer@latest

# Configure API key
# Add to $CONFIG/reconeer/config.yaml

# Run
reconeer -d example.com
reconeer -dL domains.txt -o results.txt
```

### Rate Limiting

| Tier | Limit | Notes |
|------|-------|-------|
| Free | 10 queries/day | No key required |
| Premium | Unlimited | $49/mo, API key required |

---

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
