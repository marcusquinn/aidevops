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
- **API**: REST at `https://api.ahrefs.com/v3/`
- **Auth**: Bearer token in `~/.config/aidevops/credentials.sh` as `AHREFS_API_KEY`
- **Docs**: https://docs.ahrefs.com/reference
- **No MCP required** — uses curl directly

<!-- AI-CONTEXT-END -->

## Setup

Get API key from https://app.ahrefs.com/user/api and add to `~/.config/aidevops/credentials.sh`:

```bash
export AHREFS_API_KEY="your_key_here"
```

Before calling endpoints, source credentials and set common variables:

```bash
source ~/.config/aidevops/credentials.sh
AHREFS_AUTH=(-H "Authorization: Bearer $AHREFS_API_KEY" -H "Accept: application/json")
TODAY=$(date +%Y-%m-%d)
```

All examples below use `${AHREFS_AUTH[@]}` and `$TODAY` from this block.

## Parameters

| Param | Description | Values | Required |
|-------|-------------|--------|----------|
| `target` | Domain or URL to analyze | `example.com` | Yes |
| `date` | Data snapshot date | `YYYY-MM-DD` | Yes (most endpoints) |
| `mode` | Analysis scope | `domain`, `prefix`, `exact` | Yes (most) |
| `select` | Fields to return | Comma-separated field names | Yes (list endpoints) |
| `country` | Country for organic data | `us`, `gb`, `de`, etc. | For organic endpoints |
| `limit` | Results per page | `10`–`1000` | No (default varies) |
| `offset` | Pagination offset | `0`, `50`, `100` | No |

## Site Explorer Endpoints

All require `date`. List endpoints require `select`.

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

### Volume

```bash
curl -s -X POST "${AHREFS_AUTH[@]}" -H "Content-Type: application/json" "https://api.ahrefs.com/v3/keywords-explorer/google/volume" \
  -d '{"keywords": ["keyword1", "keyword2"], "country": "us"}'
```

### Suggestions

```bash
curl -s "${AHREFS_AUTH[@]}" "https://api.ahrefs.com/v3/keywords-explorer/google/keyword-ideas?keyword=seed+keyword&country=us&limit=50&select=keyword,volume,difficulty"
```
