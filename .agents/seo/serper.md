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

- **API**: `https://google.serper.dev` — web, images, news, places, shopping, scholar, autocomplete
- **Auth**: `SERPER_API_KEY` in `~/.config/aidevops/credentials.sh`
- **Dashboard**: https://serper.dev/
- **No MCP required** — uses curl directly

```bash
source ~/.config/aidevops/credentials.sh
SERPER_CURL=(-s -X POST -H "X-API-KEY: $SERPER_API_KEY" -H "Content-Type: application/json")
```

## Endpoints

Common params: `gl` (country: `"us"`,`"gb"`,`"de"`), `hl` (lang: `"en"`), `num` (results: 10–100), `tbs` (time: `"qdr:h/d/w/m"`), `page`.

```bash
# Web
curl "${SERPER_CURL[@]}" https://google.serper.dev/search \
  -d '{"q": "query", "gl": "us", "hl": "en", "num": 10}'

# Images
curl "${SERPER_CURL[@]}" https://google.serper.dev/images \
  -d '{"q": "query", "gl": "us", "num": 20}'

# News
curl "${SERPER_CURL[@]}" https://google.serper.dev/news \
  -d '{"q": "topic", "gl": "us", "tbs": "qdr:w"}'

# Places/Local
curl "${SERPER_CURL[@]}" https://google.serper.dev/places \
  -d '{"q": "business type", "location": "City, State"}'

# Shopping
curl "${SERPER_CURL[@]}" https://google.serper.dev/shopping \
  -d '{"q": "product name", "gl": "us"}'

# Scholar
curl "${SERPER_CURL[@]}" https://google.serper.dev/scholar \
  -d '{"q": "research topic", "num": 10}'

# Autocomplete
curl "${SERPER_CURL[@]}" https://google.serper.dev/autocomplete \
  -d '{"q": "partial query"}'
```

<!-- AI-CONTEXT-END -->
