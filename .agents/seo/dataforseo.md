---
description: DataForSEO comprehensive SEO data via REST API (no MCP needed)
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# DataForSEO Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **API**: REST at `https://api.dataforseo.com/v3/`
- **Auth**: Basic auth via `DATAFORSEO_USERNAME` + `DATAFORSEO_PASSWORD` in `~/.config/aidevops/credentials.sh`
- **Docs**: <https://docs.dataforseo.com/v3/>
- **Dashboard**: <https://app.dataforseo.com/>
- **MCP config**: `configs/dataforseo-config.json.txt` (optional — curl works without MCP)

| Module | Purpose |
|--------|---------|
| `SERP` | Real-time SERP data for Google, Bing, Yahoo |
| `KEYWORDS_DATA` | Search volume, CPC, keyword research |
| `ONPAGE` | Website crawling, on-page SEO metrics |
| `DATAFORSEO_LABS` | Keywords, SERPs, domains from proprietary databases |
| `BACKLINKS` | Backlink analysis, referring domains, anchor text |
| `BUSINESS_DATA` | Business reviews (Google, Trustpilot, Tripadvisor) |
| `DOMAIN_ANALYTICS` | Website traffic, technologies, Whois |
| `CONTENT_ANALYSIS` | Brand monitoring, sentiment analysis |
| `AI_OPTIMIZATION` | Keyword discovery, LLM benchmarking |

<!-- AI-CONTEXT-END -->

## Authentication

```bash
source ~/.config/aidevops/credentials.sh
export DFS_AUTH=$(echo -n "$DATAFORSEO_USERNAME:$DATAFORSEO_PASSWORD" | base64)
```

Store credentials:

```bash
bash ~/.aidevops/agents/scripts/setup-local-api-keys.sh set DATAFORSEO_USERNAME "your_username"
bash ~/.aidevops/agents/scripts/setup-local-api-keys.sh set DATAFORSEO_PASSWORD "your_password"
```

## API Examples

### SERP Results

```bash
curl -s -X POST "https://api.dataforseo.com/v3/serp/google/organic/live/advanced" \
  -H "Authorization: Basic $DFS_AUTH" \
  -H "Content-Type: application/json" \
  -d '[{"keyword": "your keyword", "location_code": 2840, "language_code": "en"}]'
```

### Keyword Data

```bash
curl -s -X POST "https://api.dataforseo.com/v3/keywords_data/google_ads/search_volume/live" \
  -H "Authorization: Basic $DFS_AUTH" \
  -H "Content-Type: application/json" \
  -d '[{"keywords": ["keyword1", "keyword2"], "location_code": 2840, "language_code": "en"}]'
```

### Backlinks

```bash
curl -s -X POST "https://api.dataforseo.com/v3/backlinks/summary/live" \
  -H "Authorization: Basic $DFS_AUTH" \
  -H "Content-Type: application/json" \
  -d '[{"target": "example.com"}]'
```

### On-Page Crawl

```bash
curl -s -X POST "https://api.dataforseo.com/v3/on_page/task_post" \
  -H "Authorization: Basic $DFS_AUTH" \
  -H "Content-Type: application/json" \
  -d '[{"target": "example.com", "max_crawl_pages": 100}]'
```

## Environment Variables

```bash
# Required
export DATAFORSEO_USERNAME="your_username"
export DATAFORSEO_PASSWORD="your_password"

# Optional — restrict to specific modules
export ENABLED_MODULES="SERP,KEYWORDS_DATA,BACKLINKS,DATAFORSEO_LABS"

# Optional — full API responses (default: false for concise output)
export DATAFORSEO_FULL_RESPONSE="false"

# Optional — simplified filter schema for ChatGPT compatibility
export DATAFORSEO_SIMPLE_FILTER="false"
```

## MCP Server (Optional)

For MCP-based access instead of curl, see `configs/dataforseo-config.json.txt` for runtime-specific configuration (Claude Desktop, Cursor, OpenCode). Install: `npm install -g dataforseo-mcp-server` or `npx dataforseo-mcp-server`.

- **GitHub**: <https://github.com/dataforseo/mcp-server-typescript>
- **npm**: <https://www.npmjs.com/package/dataforseo-mcp-server>

## Related

- `seo/keyword-research.md` — keyword workflows using DataForSEO endpoints
- `seo/backlink-checker.md` — backlink analysis workflows
- `seo/data-export.md` — bulk data export via `seo-export-dataforseo.sh`
