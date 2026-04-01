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
- **Auth**: API key in `~/.config/aidevops/credentials.sh` as `SERPER_API_KEY`
- **Dashboard**: https://serper.dev/
- **No MCP required** - uses curl directly

<!-- AI-CONTEXT-END -->

## Setup

Get API key from https://serper.dev/ and add to `~/.config/aidevops/credentials.sh`:

```bash
export SERPER_API_KEY="your_key_here"
```

Load credentials and define reusable curl options:

```bash
source ~/.config/aidevops/credentials.sh
SERPER_CURL=(-s -X POST -H "X-API-KEY: $SERPER_API_KEY" -H "Content-Type: application/json")
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

## API Endpoints

### Web Search

```bash
curl "${SERPER_CURL[@]}" https://google.serper.dev/search \
  -d '{"q": "your search query", "gl": "us", "hl": "en", "num": 10}'
```

### Image Search

```bash
curl "${SERPER_CURL[@]}" https://google.serper.dev/images \
  -d '{"q": "your image query", "gl": "us", "num": 20}'
```

### News Search

```bash
curl "${SERPER_CURL[@]}" https://google.serper.dev/news \
  -d '{"q": "topic", "gl": "us", "tbs": "qdr:w"}'
```

### Places/Local Search

```bash
curl "${SERPER_CURL[@]}" https://google.serper.dev/places \
  -d '{"q": "business type", "location": "City, State"}'
```

### Shopping Search

```bash
curl "${SERPER_CURL[@]}" https://google.serper.dev/shopping \
  -d '{"q": "product name", "gl": "us"}'
```

### Scholar Search

```bash
curl "${SERPER_CURL[@]}" https://google.serper.dev/scholar \
  -d '{"q": "research topic", "num": 10}'
```

### Autocomplete

```bash
curl "${SERPER_CURL[@]}" https://google.serper.dev/autocomplete \
  -d '{"q": "partial query"}'
```
