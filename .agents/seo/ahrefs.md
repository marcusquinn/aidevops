---
description: Ahrefs SEO data via REST API (no MCP needed)
mode: subagent
tools:
  read: true
  bash: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Ahrefs SEO Integration

<!-- AI-CONTEXT-START -->
- **API**: `https://api.ahrefs.com/v3/` | [Docs](https://docs.ahrefs.com/reference)
- **Auth**: `AHREFS_API_KEY` in `~/.config/aidevops/credentials.sh`
- **Setup**: `AHREFS_AUTH=(-H "Authorization: Bearer $AHREFS_API_KEY" -H "Accept: application/json")`
<!-- AI-CONTEXT-END -->

## Common Parameters
| Param | Description | Values |
|-------|-------------|--------|
| `target` | Domain/URL | `example.com` |
| `date` | Snapshot | `YYYY-MM-DD` |
| `mode` | Scope | `domain`, `prefix`, `exact` |
| `select` | Fields | `keyword,volume,traffic` |
| `country` | Country | `us`, `gb`, etc. |

## Site Explorer
All require `date=$TODAY` and `select`.

### Domain Rating & Metrics
```bash
curl -s "${AHREFS_AUTH[@]}" "https://api.ahrefs.com/v3/site-explorer/domain-rating?target=example.com&date=$TODAY"
curl -s "${AHREFS_AUTH[@]}" "https://api.ahrefs.com/v3/site-explorer/metrics?target=example.com&mode=domain&date=$TODAY"
```

### Backlinks & Referring Domains
```bash
curl -s "${AHREFS_AUTH[@]}" "https://api.ahrefs.com/v3/site-explorer/all-backlinks?target=example.com&mode=domain&date=$TODAY&limit=50&select=url_from,ahrefs_rank,anchor"
curl -s "${AHREFS_AUTH[@]}" "https://api.ahrefs.com/v3/site-explorer/refdomains?target=example.com&mode=domain&date=$TODAY&limit=50&select=domain,domain_rating,backlinks"
```

### Organic Keywords & Top Pages
```bash
curl -s "${AHREFS_AUTH[@]}" "https://api.ahrefs.com/v3/site-explorer/organic-keywords?target=example.com&mode=domain&country=us&date=$TODAY&limit=50&select=keyword,position,volume,traffic"
curl -s "${AHREFS_AUTH[@]}" "https://api.ahrefs.com/v3/site-explorer/top-pages?target=example.com&mode=domain&country=us&date=$TODAY&limit=50&select=url,sum_traffic,keywords"
```

## Keywords Explorer (Google)

### Volume & Suggestions
```bash
curl -s -X POST "${AHREFS_AUTH[@]}" -H "Content-Type: application/json" "https://api.ahrefs.com/v3/keywords-explorer/google/volume" -d '{"keywords": ["k1", "k2"], "country": "us"}'
curl -s "${AHREFS_AUTH[@]}" "https://api.ahrefs.com/v3/keywords-explorer/google/keyword-ideas?keyword=seed&country=us&limit=50&select=keyword,volume,difficulty"
```
