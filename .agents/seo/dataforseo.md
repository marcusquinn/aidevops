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

- **API**: REST at `https://api.dataforseo.com/v3/`, HTTP Basic auth with the **API login + API password**.
- **API password ≠ account password**: DataForSEO issues a separate API password (Dashboard → API Access). The account/dashboard login password returns HTTP 401.
- **Store credentials** (gopass, encrypted): `aidevops secret set DATAFORSEO_API_LOGIN` and `aidevops secret set DATAFORSEO_API_PASSWORD`. Never paste values into chat.
- **Test the connection for free** before paid work: `/v3/appendix/user_data` returns balance and costs 0 (see Authentication).
- **Spend**: paid calls debit the account balance. Recurring rank tracking goes through `aidevops keywords` (budget-gated, default $1/property/month); see `seo/keywords-standard.md`. Check pricing before bulk calls.
- **Docs**: <https://docs.dataforseo.com/v3/> · **Dashboard**: <https://app.dataforseo.com/>
- **MCP config**: repo `configs/dataforseo-config.json.txt` (optional — curl works without MCP)

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

## Credential sources

Tools receive credentials as the environment variables `DATAFORSEO_USERNAME` (API login) and `DATAFORSEO_PASSWORD` (API password). The shared `scripts/dataforseo-credentials.sh` resolver supplies all listed consumers:

| Consumers | Resolution order |
|-----------|------------------|
| `aidevops keywords` (incl. Pulse), DataForSEO MCP server, `seo-export-dataforseo.sh`, `keyword-research-helper-providers.sh` | env → `credentials.sh` → gopass `DATAFORSEO_API_LOGIN`/`DATAFORSEO_API_PASSWORD` → legacy gopass `DATAFORSEO_USERNAME`/`DATAFORSEO_PASSWORD` |

The resolver exports the pair for each consumer without displaying values. To inject credentials into an unrelated command without copying them to plaintext `credentials.sh`, map the names inside an injected shell:

```bash
aidevops secret DATAFORSEO_API_LOGIN DATAFORSEO_API_PASSWORD -- bash -c \
  'DATAFORSEO_USERNAME="$DATAFORSEO_API_LOGIN" DATAFORSEO_PASSWORD="$DATAFORSEO_API_PASSWORD" <command>'
```

## Authentication

Free connection check (no balance used; prints status and balance only):

```bash
aidevops secret DATAFORSEO_API_LOGIN DATAFORSEO_API_PASSWORD -- bash -c \
  'curl -s -u "$DATAFORSEO_API_LOGIN:$DATAFORSEO_API_PASSWORD" \
     https://api.dataforseo.com/v3/appendix/user_data \
   | jq "{status_code, cost, balance: .tasks[0].result[0].money.balance}"'
```

`status_code: 20000` and `cost: 0` mean the credentials work. HTTP 401 usually means the account password was stored instead of the API password.

Inside an injected shell, build the header once:

```bash
DFS_AUTH=$(printf '%s:%s' "$DATAFORSEO_API_LOGIN" "$DATAFORSEO_API_PASSWORD" | base64 | tr -d '\n')
```

## API Examples

All examples assume `DFS_AUTH` from the injected shell above. Each live call is billed.

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

## Optional MCP settings

```bash
# Restrict to specific modules
export ENABLED_MODULES="SERP,KEYWORDS_DATA,BACKLINKS,DATAFORSEO_LABS"
# Full API responses (default: false for concise output)
export DATAFORSEO_FULL_RESPONSE="false"
# Simplified filter schema for ChatGPT compatibility
export DATAFORSEO_SIMPLE_FILTER="false"
```

## MCP Server (Optional)

For MCP-based access instead of curl, see repo `configs/dataforseo-config.json.txt` for runtime-specific configuration (Claude Desktop, Cursor, OpenCode). The generated OpenCode entry uses the shared resolver. Install: `npm install -g dataforseo-mcp-server` or `npx dataforseo-mcp-server`.

- **GitHub**: <https://github.com/dataforseo/mcp-server-typescript>
- **npm**: <https://www.npmjs.com/package/dataforseo-mcp-server>

## Related

- `seo/keywords-standard.md` — per-repo search targets, budget-gated DataForSEO rank tracking and routines
- `seo/keyword-research.md` — keyword workflows using DataForSEO endpoints
- `seo/backlink-checker.md` — backlink analysis workflows
- `seo/data-export.md` — bulk data export via `seo-export-dataforseo.sh`
