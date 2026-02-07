---
description: Backlink monitoring and expired domain discovery for link reclamation
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

# Backlink & Expired Domain Checker

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Monitor backlinks, detect lost/broken links, find expired referring domains for purchase
- **Data Sources**: Ahrefs API, DataForSEO Backlinks API, WHOIS lookups
- **Helpers**: `scripts/seo-export-ahrefs.sh`, `scripts/seo-export-dataforseo.sh` (backlink data export)

**Workflow**: Fetch backlink profile -> Identify lost/broken links -> Check domain expiry status -> Rank by DA/DR/traffic value -> Output purchase candidates

<!-- AI-CONTEXT-END -->

## Data Sources

### Ahrefs API (Primary)

> See `scripts/seo-export-ahrefs.sh` for the export implementation.

Ahrefs endpoints used:
- `/v3/site-explorer/all-backlinks` - Full backlink list
- `/v3/site-explorer/backlinks-new-lost` - New/lost link changes
- `/v3/site-explorer/referring-domains` - Unique referring domains

### DataForSEO Backlinks API (Alternative)

> See `scripts/seo-export-dataforseo.sh` for the export implementation.

DataForSEO endpoints:
- `/v3/backlinks/backlinks/live` - Live backlink data
- `/v3/backlinks/referring_domains/live` - Referring domains
- `/v3/backlinks/bulk_new_lost_backlinks/live` - Bulk new/lost

## Expired Domain Detection

### WHOIS Lookup

```bash
# Check if a referring domain has expired
whois example-referrer.com | grep -i "expir"

# Batch check (pipe from backlink export)
seo-helper.sh backlinks example.com --referring-domains-only | while read -r domain; do
    expiry=$(whois "$domain" 2>/dev/null | grep -i "expiry\|expiration" | head -1)
    echo "$domain: $expiry"
done
```

### Domain Availability Tools

| Tool | Type | Notes |
|------|------|-------|
| `whois` CLI | Free | Rate-limited, varies by TLD |
| expired-domains.co | Web | Aggregates expired domain lists |
| expireddomains.net | Web | Filters by DA, backlinks, age |
| GoDaddy Auctions API | API | Auction/aftermarket domains |
| Namecheap API | API | Registration availability check |

### GitHub Tools for Expired Domain Discovery

- [peterprototypes/expired-domains](https://github.com/peterprototypes/expired-domains) - Rust CLI for checking domain expiry
- [Jeongseup/expired-domain-finder](https://github.com/Jeongseup/expired-domain-finder) - Python bulk checker

## Reclamation Workflow

1. **Export referring domains** with DR/DA scores
2. **Filter lost/broken** links from last 90 days
3. **WHOIS check** each lost referring domain
4. **Score candidates** by:
   - Domain Rating (DR) or Domain Authority (DA)
   - Number of backlinks the domain had
   - Traffic estimate (Ahrefs/SimilarWeb)
   - Registration cost vs. link value
5. **Output ranked list** of purchase candidates

The full reclamation pipeline combines backlink export with WHOIS checks. Use the Ahrefs or DataForSEO export scripts to get lost backlinks, then pipe through WHOIS lookups above.

## Integration with aidevops

- Pairs with `seo/ahrefs.md` for API access
- Pairs with `seo/dataforseo.md` for alternative data source
- Pairs with `seo/domain-research.md` for DNS intelligence on candidates
- Results can feed into `seo/link-building.md` workflows

## Related

- `seo/ahrefs.md` - Ahrefs API integration
- `seo/dataforseo.md` - DataForSEO API integration
- `seo/domain-research.md` - DNS reconnaissance
- `seo/link-building.md` - Link-building strategies
