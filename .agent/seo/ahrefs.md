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

### Site Explorer - Overview

```bash
curl -s "https://api.ahrefs.com/v3/site-explorer/overview?target=example.com&mode=domain" \
  -H "Authorization: Bearer $AHREFS_API_KEY" \
  -H "Accept: application/json"
```

### Backlinks

```bash
curl -s "https://api.ahrefs.com/v3/site-explorer/backlinks?target=example.com&mode=domain&limit=50" \
  -H "Authorization: Bearer $AHREFS_API_KEY"
```

### Referring Domains

```bash
curl -s "https://api.ahrefs.com/v3/site-explorer/refdomains?target=example.com&mode=domain&limit=50" \
  -H "Authorization: Bearer $AHREFS_API_KEY"
```

### Organic Keywords

```bash
curl -s "https://api.ahrefs.com/v3/site-explorer/organic-keywords?target=example.com&mode=domain&country=us&limit=50" \
  -H "Authorization: Bearer $AHREFS_API_KEY"
```

### Organic Pages

```bash
curl -s "https://api.ahrefs.com/v3/site-explorer/top-pages?target=example.com&mode=domain&country=us&limit=50" \
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
curl -s "https://api.ahrefs.com/v3/keywords-explorer/google/keyword-ideas?keyword=seed+keyword&country=us&limit=50" \
  -H "Authorization: Bearer $AHREFS_API_KEY"
```

### Domain Rating

```bash
curl -s "https://api.ahrefs.com/v3/site-explorer/domain-rating?target=example.com" \
  -H "Authorization: Bearer $AHREFS_API_KEY"
```

## Parameters

| Param | Description | Values |
|-------|-------------|--------|
| `target` | Domain or URL to analyze | `example.com` |
| `mode` | Analysis scope | `domain`, `prefix`, `exact` |
| `country` | Country for organic data | `us`, `gb`, `de`, etc. |
| `limit` | Results per page | `10`-`1000` |
| `offset` | Pagination offset | `0`, `50`, `100` |

## Setup

Get API key from https://app.ahrefs.com/user/api and add to `~/.config/aidevops/mcp-env.sh`:

```bash
export AHREFS_API_KEY="your_key_here"
```
