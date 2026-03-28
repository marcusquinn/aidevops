# Domain Research - API Reference

Detailed endpoint documentation for THC and Reconeer APIs. Parent: `seo/domain-research.md`.

## THC API

**4.51 billion records.** Base URL: `https://ip.thc.org`. Rate limit: 250 requests, 0.5/sec replenish (~8 min full recovery). Helper handles backoff automatically.

### Simple CLI Endpoints

| Endpoint | Purpose | Example |
|----------|---------|---------|
| `/{ip}` | Reverse DNS | `curl https://ip.thc.org/1.1.1.1` |
| `/me` | Your IP's rDNS | `curl https://ip.thc.org/me` |
| `/sb/{domain}` | Subdomain lookup | `curl https://ip.thc.org/sb/wikipedia.org` |
| `/cn/{domain}` | CNAME lookup | `curl https://ip.thc.org/cn/github.io` |

Query params: `f=example.com` (filter by apex) | `l=50` (limit, max 100) | `nocolor=1` | `raw=1` | `noheader=1`

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

`ASN` | `Org` | `City` | `Country` | `GPS` | `Entries` (results/total) | `Rate Limit` (remaining + replenish rate)

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
