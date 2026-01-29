---
description: Google Search results via Serper API (curl-based, no MCP needed)
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  grep: true
---

# Serper - Google Search API

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Google Search results (web, images, news, places, shopping, scholar)
- **API**: `https://google.serper.dev`
- **Auth**: API key in `~/.config/aidevops/mcp-env.sh` as `SERPER_API_KEY`
- **Dashboard**: https://serper.dev/
- **No MCP required** - uses curl directly

<!-- AI-CONTEXT-END -->

## Authentication

```bash
source ~/.config/aidevops/mcp-env.sh
```

## API Endpoints

### Web Search

```bash
curl -s -X POST https://google.serper.dev/search \
  -H "X-API-KEY: $SERPER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"q": "your search query", "gl": "us", "hl": "en", "num": 10}'
```

### Image Search

```bash
curl -s -X POST https://google.serper.dev/images \
  -H "X-API-KEY: $SERPER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"q": "your image query", "gl": "us", "num": 20}'
```

### News Search

```bash
curl -s -X POST https://google.serper.dev/news \
  -H "X-API-KEY: $SERPER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"q": "topic", "gl": "us", "tbs": "qdr:w"}'
```

### Places/Local Search

```bash
curl -s -X POST https://google.serper.dev/places \
  -H "X-API-KEY: $SERPER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"q": "business type", "location": "City, State"}'
```

### Shopping Search

```bash
curl -s -X POST https://google.serper.dev/shopping \
  -H "X-API-KEY: $SERPER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"q": "product name", "gl": "us"}'
```

### Scholar Search

```bash
curl -s -X POST https://google.serper.dev/scholar \
  -H "X-API-KEY: $SERPER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"q": "research topic", "num": 10}'
```

### Autocomplete

```bash
curl -s -X POST https://google.serper.dev/autocomplete \
  -H "X-API-KEY: $SERPER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"q": "partial query"}'
```

## Parameters

| Param | Description | Example |
|-------|-------------|---------|
| `q` | Search query | `"best seo tools"` |
| `gl` | Country code | `"us"`, `"gb"`, `"de"` |
| `hl` | Language | `"en"`, `"de"`, `"fr"` |
| `num` | Results count | `10`, `20`, `100` |
| `tbs` | Time filter | `"qdr:h"` (hour), `"qdr:d"` (day), `"qdr:w"` (week), `"qdr:m"` (month) |
| `page` | Page number | `1`, `2`, `3` |

## Setup

Get API key from https://serper.dev/ and add to `~/.config/aidevops/mcp-env.sh`:

```bash
export SERPER_API_KEY="your_key_here"
```
