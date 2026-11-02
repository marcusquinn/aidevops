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

## Local pack / Maps grid collection

Use when matching SEO Utils grid data is unavailable or unreachable. Metric definitions, required scan metadata and guardrails: `seo/seo-utils.md` "Geogrid metrics". Source order: matching, reachable SEO Utils data, then this recipe, then `seo/serpapi.md`.

Recipe: one Google Maps SERP task per grid point, with the point passed as `location_coordinate` in `"latitude,longitude,zoom"` format (max 7 decimals; zoom 3z-21z; default 17z). Do not send `location_code` or `location_name` alongside it. Keep `keyword`, `language_code`, `device` and `depth` identical across points. Set `depth` to the cutoff `C` (default 100; billing is per SERP of up to 100 results, so a small `depth` does not cut the price). Store each task's `tag` as the grid point ID, and read the business's `rank_group` for `type: maps_search` items, matching on `place_id` or `cid`.

For this recipe, provision a protected netrc file at `~/.config/aidevops/dataforseo.netrc` through your credential manager (parent directory mode 700, file mode 600). Its entry must use `machine api.dataforseo.com`, with the API login and API password from the secret store. Never print its contents or enable shell tracing or curl verbose/trace logs. Unlike an expanded authorization header, the example below keeps credentials out of curl's process arguments.

```bash
# One billed task per point; only the protected file path appears in argv.
curl -s -X POST "https://api.dataforseo.com/v3/serp/google/maps/task_post" \
  --netrc-file "$HOME/.config/aidevops/dataforseo.netrc" -H "Content-Type: application/json" \
  -d '[{"keyword": "plumber", "location_coordinate": "51.5074,-0.1278,15z", "language_code": "en", "device": "mobile", "depth": 20, "tag": "p01"}]'
```

Cost before running: `cost = points × keywords × price_per_task` (+ the priority surcharge if `priority: 2`). Example: a 7×7 grid is 49 points; 3 keywords = 147 tasks; 147 × `<price_per_task>` from the DataForSEO pricing page (Google Maps SERP). Show this total and get approval before submitting; a repeat scan multiplies it.

Split task arrays into batches of at most 100 tasks per `task_post` request (147 tasks require batches of 100 and 47). Approval covers the entire scan, not just the first batch.

Standard queue vs live:

- **Standard queue** (`task_post`, then `tasks_ready` and `task_get`, or `postback_url`/`pingback_url`): the cheaper default for scheduled grids. Fetch the `endpoint_advanced` returned by `tasks_ready`, or `/v3/serp/google/maps/task_get/advanced/{id}`, for the Maps fields above and `check_url`. When using `postback_url`, set `postback_data: "advanced"`; a `pingback_url` notification still requires fetching the advanced result. `priority` 1 (default) is normal; `priority` 2 is high and carries an extra charge.
- **Live** (`/v3/serp/google/maps/live/advanced`): results in the response, one task per call, at the live price. Use for a small spot check, not full grids.

Verify before use: current per-task prices and queue turnaround on the pricing page, and the live and `task_post` parameter lists, at <https://docs.dataforseo.com/v3/serp/google/maps/task_post/> and <https://docs.dataforseo.com/v3/serp/google/maps/live/advanced/>. After approval, submit one planned grid task and check it against the returned `check_url` before submitting the rest; reuse its result as that grid point rather than billing it twice. If using a separate live spot check or repeating a task, include that additional billed cost in the total before approval. Posting a task incurs its charge.

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
