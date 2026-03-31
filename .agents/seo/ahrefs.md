---
description: Ahrefs SEO data via REST API (no MCP needed)
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  grep: true
---

# Ahrefs SEO Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Backlink analysis, keyword research, site audit, rank tracking
- **API**: `https://api.ahrefs.com/v3/`
- **Auth**: `AHREFS_API_KEY` in `~/.config/aidevops/credentials.sh`
- **Docs**: https://docs.ahrefs.com/reference
- **No MCP required** — uses curl directly

<!-- AI-CONTEXT-END -->

## Setup

Get an API key from https://app.ahrefs.com/user/api, then set shared shell vars:

```bash
export AHREFS_API_KEY="your_key_here"
source ~/.config/aidevops/credentials.sh
AHREFS_AUTH=(-H "Authorization: Bearer $AHREFS_API_KEY" -H "Accept: application/json")
TODAY=$(date +%Y-%m-%d)
```

All examples use `${AHREFS_AUTH[@]}` and `$TODAY` from this block.

## Common Parameters

| Param | Description | Values | Required |
|-------|-------------|--------|----------|
| `target` | Domain or URL to analyze | `example.com` | Yes |
| `date` | Data snapshot | `YYYY-MM-DD` | Yes (most endpoints) |
| `mode` | Scope | `domain`, `prefix`, `exact` | Yes (most) |
| `select` | Fields to return | Comma-separated field names | Yes (list endpoints) |
| `country` | Country code for organic data | `us`, `gb`, `de`, etc. | Organic endpoints |
| `limit` | Results per page | `10`–`1000` | No |
| `offset` | Pagination offset | `0`, `50`, `100` | No |

## Site Explorer Endpoints

`date` is required for all examples below. List endpoints also require `select`.

### Domain Rating

```bash
curl -s "${AHREFS_AUTH[@]}" "https://api.ahrefs.com/v3/site-explorer/domain-rating?target=example.com&date=$TODAY"
```

### Metrics (Overview)

```bash
curl -s "${AHREFS_AUTH[@]}" "https://api.ahrefs.com/v3/site-explorer/metrics?target=example.com&mode=domain&date=$TODAY"
```

### Backlinks

```bash
curl -s "${AHREFS_AUTH[@]}" "https://api.ahrefs.com/v3/site-explorer/all-backlinks?target=example.com&mode=domain&date=$TODAY&limit=50&select=url_from,ahrefs_rank,anchor,first_seen"
```

### Referring Domains

```bash
curl -s "${AHREFS_AUTH[@]}" "https://api.ahrefs.com/v3/site-explorer/refdomains?target=example.com&mode=domain&date=$TODAY&limit=50&select=domain,domain_rating,backlinks"
```

### Organic Keywords

```bash
curl -s "${AHREFS_AUTH[@]}" "https://api.ahrefs.com/v3/site-explorer/organic-keywords?target=example.com&mode=domain&country=us&date=$TODAY&limit=50&select=keyword,position,volume,traffic"
```

### Top Pages

```bash
curl -s "${AHREFS_AUTH[@]}" "https://api.ahrefs.com/v3/site-explorer/top-pages?target=example.com&mode=domain&country=us&date=$TODAY&limit=50&select=url,sum_traffic,keywords"
```

## Keywords Explorer Endpoints

Google examples use the `keywords-explorer/google/*` routes.

### Volume

```bash
curl -s -X POST "${AHREFS_AUTH[@]}" -H "Content-Type: application/json" "https://api.ahrefs.com/v3/keywords-explorer/google/volume" \
  -d '{"keywords": ["keyword1", "keyword2"], "country": "us"}'
```

### Suggestions

```bash
curl -s "${AHREFS_AUTH[@]}" "https://api.ahrefs.com/v3/keywords-explorer/google/keyword-ideas?keyword=seed+keyword&country=us&limit=50&select=keyword,volume,difficulty"
```
