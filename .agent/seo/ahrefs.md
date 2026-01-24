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
- **Auth**: Bearer token in `~/.config/aidevops/mcp-env.sh` as `AHREFS_API_KEY`
- **Docs**: https://docs.ahrefs.com/reference
- **No MCP required** - uses curl directly

<!-- AI-CONTEXT-END -->

## Authentication

```bash
source ~/.config/aidevops/mcp-env.sh
```

## API Endpoints

All Site Explorer endpoints require `date` (YYYY-MM-DD) and most list endpoints require `select` (comma-separated fields).

### Domain Rating

```bash
curl -s "https://api.ahrefs.com/v3/site-explorer/domain-rating?target=example.com&date=$(date +%Y-%m-%d)" \
  -H "Authorization: Bearer $AHREFS_API_KEY" \
  -H "Accept: application/json"
```

### Metrics (Overview)

```bash
curl -s "https://api.ahrefs.com/v3/site-explorer/metrics?target=example.com&mode=domain&date=$(date +%Y-%m-%d)" \
  -H "Authorization: Bearer $AHREFS_API_KEY" \
  -H "Accept: application/json"
```

### Backlinks

```bash
curl -s "https://api.ahrefs.com/v3/site-explorer/all-backlinks?target=example.com&mode=domain&date=$(date +%Y-%m-%d)&limit=50&select=url_from,ahrefs_rank,anchor,first_seen" \
  -H "Authorization: Bearer $AHREFS_API_KEY"
```

### Referring Domains

```bash
curl -s "https://api.ahrefs.com/v3/site-explorer/refdomains?target=example.com&mode=domain&date=$(date +%Y-%m-%d)&limit=50&select=domain,domain_rating,backlinks" \
  -H "Authorization: Bearer $AHREFS_API_KEY"
```

### Organic Keywords

```bash
curl -s "https://api.ahrefs.com/v3/site-explorer/organic-keywords?target=example.com&mode=domain&country=us&date=$(date +%Y-%m-%d)&limit=50&select=keyword,position,volume,traffic" \
  -H "Authorization: Bearer $AHREFS_API_KEY"
```

### Top Pages

```bash
curl -s "https://api.ahrefs.com/v3/site-explorer/top-pages?target=example.com&mode=domain&country=us&date=$(date +%Y-%m-%d)&limit=50&select=url,sum_traffic,keywords" \
  -H "Authorization: Bearer $AHREFS_API_KEY"
```

### Keywords Explorer - Volume

```bash
curl -s -X POST "https://api.ahrefs.com/v3/keywords-explorer/google/volume" \
  -H "Authorization: Bearer $AHREFS_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"keywords": ["keyword1", "keyword2"], "country": "us"}'
```

### Keywords Explorer - Suggestions

```bash
curl -s "https://api.ahrefs.com/v3/keywords-explorer/google/keyword-ideas?keyword=seed+keyword&country=us&limit=50&select=keyword,volume,difficulty" \
  -H "Authorization: Bearer $AHREFS_API_KEY"
```

## Parameters

| Param | Description | Values | Required |
|-------|-------------|--------|----------|
| `target` | Domain or URL to analyze | `example.com` | Yes |
| `date` | Data snapshot date | `YYYY-MM-DD` | Yes (most endpoints) |
| `mode` | Analysis scope | `domain`, `prefix`, `exact` | Yes (most) |
| `select` | Fields to return | Comma-separated field names | Yes (list endpoints) |
| `country` | Country for organic data | `us`, `gb`, `de`, etc. | For organic endpoints |
| `limit` | Results per page | `10`-`1000` | No (default varies) |
| `offset` | Pagination offset | `0`, `50`, `100` | No |

## Setup

Get API key from https://app.ahrefs.com/user/api and add to `~/.config/aidevops/mcp-env.sh`:

```bash
export AHREFS_API_KEY="your_key_here"
```
