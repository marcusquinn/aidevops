---
description: Outscraper business data extraction via REST API (no MCP needed)
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

# Outscraper Data Extraction

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Business intelligence from Google Maps, Amazon, reviews, contacts
- **Auth**: `X-API-KEY` header; key from <https://auth.outscraper.com/profile>
- **Env Var**: `OUTSCRAPER_API_KEY` in `~/.config/aidevops/credentials.sh` (600 perms)
- **API Bases**: `https://api.app.outscraper.com` and `https://api.outscraper.cloud` (both supported; authenticated `GET /profile/balance` returned HTTP 200 on both on 2026-10-08)
- **Docs**: Live docs require Outscraper login: <https://app.outscraper.cloud/api-docs> (SPA; text fetches may return only the title — use SDK sources below)
- **Context7 OpenAPI snapshot**: <https://context7.com/openapi/uploaded-f547ce23-outscraper-api-docs.json> — user-uploaded convenience copy; may be outdated because the latest Outscraper API docs are only available after login
- **SDK**: <https://github.com/outscraper/outscraper-python>
- **Pricing**: Metered per request — <https://outscraper.com/pricing/> (free tier available)
- **No MCP required** — curl works directly; MCP server available for tool-based access

**MCP Tools** (25+): `google_maps_search`, `google_maps_reviews`, `google_maps_photos`, `google_maps_directions`, `google_search`, `google_search_news`, `google_play_reviews`, `amazon_reviews`, `tripadvisor_reviews`, `apple_store_reviews`, `youtube_comments`, `g2_reviews`, `trustpilot_reviews`, `glassdoor_reviews`, `capterra_reviews`, `yelp_reviews`, `emails_and_contacts`, `contacts_and_leads`, `phones_enricher`, `company_insights`, `email_validation`, `whitepages_phones`, `whitepages_addresses`, `amazon_products`, `company_websites_finder`, `similarweb`, `yelp_search`, `trustpilot_search`, `yellowpages_search`, `geocoding`, `reverse_geocoding`

**Direct API** (not in MCP): `GET /profile/balance`, `GET /invoices`, `POST /tasks`, `GET /webhook-calls`, `GET /locations`

**Verification**: `Search for coffee shops near Times Square NYC using Google Maps search and return the top 5 results with ratings.`

**Tested tools** (Dec 2024): `google_search` — working; `google_maps_search` — working (minor null field warnings, non-blocking)

<!-- AI-CONTEXT-END -->

## Installation

Python 3.10+ required. `uv` recommended.

```bash
uvx outscraper-mcp-server          # run via uvx (recommended)
uv add outscraper-mcp-server       # install permanently
pip install outscraper-mcp-server  # or via pip
```

## MCP Server Config

**Claude Code CLI** (recommended):

```bash
claude mcp add-json outscraper --scope user '{
  "type": "stdio",
  "command": "uvx",
  "args": ["outscraper-mcp-server"],
  "env": {"OUTSCRAPER_API_KEY": "your_api_key_here"}
}'
```

**Standard JSON config** — used by Cursor, Windsurf, Gemini CLI, VS Code, Kilo Code, Kiro, Droid:

```json
{
  "mcpServers": {
    "outscraper": {
      "command": "uvx",
      "args": ["outscraper-mcp-server"],
      "env": { "OUTSCRAPER_API_KEY": "your_api_key_here" }
    }
  }
}
```

Config file locations:

| Runtime | Config path |
|---------|-------------|
| Cursor | Settings > Tools & MCP > New MCP Server |
| Windsurf | `~/.codeium/windsurf/mcp_config.json` |
| Gemini CLI | `~/.gemini/settings.json` (user) or `.gemini/settings.json` (project) |
| VS Code | `.vscode/mcp.json` (use `"type": "stdio"` wrapper) |
| Kilo Code | MCP server icon > Edit Global MCP (`"alwaysAllow": ["google_maps_search", "google_search"]`) |
| Kiro | Cmd+Shift+P > "Kiro: Open user MCP config" (`"autoApprove"` instead of `"alwaysAllow"`) |
| Droid | `droid mcp add outscraper "uvx" outscraper-mcp-server --env OUTSCRAPER_API_KEY=your_api_key_here` |
| Smithery | `npx -y @smithery/cli install outscraper-mcp-server --client claude` |

**OpenCode** (`~/.config/opencode/opencode.json`) — `"env"` key not supported, use bash wrapper:

```json
"outscraper": {
  "type": "local",
  "command": ["/bin/bash", "-c", "OUTSCRAPER_API_KEY=$OUTSCRAPER_API_KEY uv tool run outscraper-mcp-server"],
  "enabled": true
}
```

OpenCode access: `@outscraper` subagent only (not enabled for main agents).

## API Reference

| Category | Endpoints |
|----------|-----------|
| **Account** | `GET /profile/balance` (balance/status), `GET /invoices` |
| **Tasks** | `GET/POST /tasks`, `POST /tasks-validate` (estimate cost), `PUT/DELETE /tasks/{id}` |
| **Requests** | `GET /requests` (recent, up to 100), `GET /requests/{id}` (async results), `GET /webhook-calls` (failed, last 24h), `GET /locations` |
| **Google** | `GET /google-search-v3`, `GET /google-search-news`, `POST /google-maps-search`, `GET /maps/reviews-v3`, `GET /maps/photos-v3`, `GET /maps/directions`, `GET /google-play/reviews` |
| **Amazon** | `GET /amazon/products-v2`, `GET /amazon/reviews` |
| **Reviews** | `GET /yelp-search`, `GET /yelp/reviews`, `GET /tripadvisor/reviews`, `GET /appstore/reviews`, `GET /youtube-comments`, `GET /g2/reviews`, `GET /trustpilot`, `GET /trustpilot/reviews`, `GET /glassdoor/reviews`, `GET /capterra-reviews` |
| **Business** | `GET /emails-and-contacts`, `GET /contacts-and-leads`, `GET /phones-enricher`, `GET /company-insights`, `GET /email-validator`, `GET /company-website-finder`, `GET /similarweb`, `GET /yellowpages-search` |
| **Businesses / POI database** | `POST /businesses` (filtered search), `GET /businesses/{business_id}` (details by `os_id`, `place_id`, or `google_id`) |
| **Geo** | `GET /geocoding`, `GET /reverse-geocoding` |
| **Whitepages** | `GET /whitepages-phones`, `GET /whitepages-addresses` |

### Common Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `query` | string/list | Search query or queries (up to 250) |
| `limit` | int | Maximum results per query |
| `language` | string | Language code (e.g., `en`, `de`, `es`) |
| `region` | string | Country code (e.g., `US`, `GB`, `CA`) |
| `fields` | string/list | Fields to include in response |
| `async` | bool | Submit async and retrieve later |
| `ui` | bool | Execute as UI task |
| `webhook` | string | Callback URL for completion notification |

### Businesses / POI Database Parameters

`POST /businesses` accepts a JSON body. These parameters are specific to the database API, not the live Google Maps scraper:

| Parameter | Type | Description |
|-----------|------|-------------|
| `filters` | object | Optional filtering criteria (see below) |
| `limit` | int | Page size, 1–1000; SDK default: 10 |
| `cursor` | string | Omit on the first page; pass the previous response's `next_cursor` for the next page |
| `include_total` | bool | Request the total matching count; default: false; may increase response time |
| `fields` | list of strings | Select response fields; omit to return all fields |
| `enrichments` | object | Map enrichment names to parameter objects, e.g. `contacts_n_leads`; the Python SDK also accepts a name string or list and normalizes it to this object |

Supported `filters` include `country_code` (string); `states`, `cities`, `types`, and `business_statuses` (lists of strings); `has_website`, `has_phone`, `verified`, and `area_service` (booleans); and `rating` and `reviews` (string expressions). Consult `outscraper/schema/businesses.py` for the full filter schema.

Example JSON body:

```json
{
  "filters": {"country_code": "US", "cities": ["New York"], "has_website": true},
  "limit": 100,
  "include_total": false,
  "fields": ["os_id", "name", "website"],
  "enrichments": {"contacts_n_leads": {"contacts_per_company": 3, "emails_per_contact": 1}}
}
```

Search responses contain `items`, `next_cursor`, and `has_more`. Continue with `next_cursor` while more pages are indicated. `GET /businesses/{business_id}` returns one business and accepts `fields` as a comma-separated query parameter. Python SDK equivalents are `client.businesses.search(...)`, `client.businesses.iter_search(...)`, and `client.businesses.get(business_id, fields=[...])`; PHP equivalents are `businessesSearch`, `businessesIterSearch`, and `businessesGet`.

### Google Maps Enrichments and Async Results

For `POST /google-maps-search`, use `enrichment` (singular), a list of service names: `domains_service`, `emails_validator_service`, `disposable_email_checker`, `whatsapp_checker`, `imessage_checker`, `phones_enricher_service`, `trustpilot_service`, and `companies_data`. This differs from the Businesses API's `enrichments` parameter.

Async results are retained for **2 hours after completion**. Retrieve them via `GET /requests/{id}` (Python: `get_request_archive`) and persist the data within that window; do not treat the request archive as permanent storage.

### SDK Sources When Live Docs Cannot Be Fetched

The docs SPA may return only a title to WebFetch. Context7's uploaded OpenAPI snapshot and SDK docstring URLs may be stale; consult current official SDK source for endpoint payloads and exported methods instead. The Businesses and Maps contracts above were checked against Python SDK 6.0.5 on 2026-10-08.

```bash
gh api repos/outscraper/outscraper-python/contents/outscraper/businesses.py --jq '.content' | base64 --decode
gh api repos/outscraper/outscraper-python/contents/outscraper/schema/businesses.py --jq '.content' | base64 --decode
gh api repos/outscraper/outscraper-python/contents/examples/Businesses.md --jq '.content' | base64 --decode
gh api repos/outscraper/outscraper-python/contents/outscraper/client.py --jq '.content' | base64 --decode
gh api repos/outscraper/outscraper-php/contents/outscraper.php --jq '.content' | base64 --decode
```

## Python SDK

```python
from outscraper import ApiClient
import requests, time

client = ApiClient(api_key='YOUR_API_KEY')
API_BASE = 'https://api.app.outscraper.com'
headers = {'X-API-KEY': 'YOUR_API_KEY'}

# Account & billing (direct API only)
balance = requests.get(f'{API_BASE}/profile/balance', headers=headers).json()
invoices = requests.get(f'{API_BASE}/invoices', headers=headers).json()

# Task management (direct API only)
task_data = {"service": "google_maps_search", "query": ["coffee shops manhattan"], "limit": 50}
estimate = requests.post(f'{API_BASE}/tasks-validate', headers=headers, json=task_data).json()
task_id = requests.post(f'{API_BASE}/tasks', headers=headers, json=task_data).json()['id']
tasks, has_more = client.get_tasks(page_size=1)
requests.delete(f'{API_BASE}/tasks/{task_id}', headers=headers)

# Async pattern
results = client.google_maps_search('restaurants brooklyn usa', limit=100, async_request=True)
request_id = results['id']
while True:
    result = client.get_request_archive(request_id)
    if result['status'] != 'Pending':
        break
    time.sleep(5)
data = result.get('data', [])

# Webhook integration
client.google_maps_reviews(
    'ChIJrc9T9fpYwokRdvjYRHT8nI4', reviews_limit=100,
    async_request=True, webhook='https://your-server.com/outscraper-callback'
)
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `OUTSCRAPER_API_KEY not set` | `export OUTSCRAPER_API_KEY="your_key_here"` |
| `uvx: command not found` | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| Connection refused / timeout | Check key at <https://auth.outscraper.com/profile>; verify connectivity |
| Tool not found | Ensure MCP server enabled; restart AI tool; check agent has `outscraper_*: true` |
| `uvx` conflicts | Use `uv tool run outscraper-mcp-server` instead |
| Python version errors | `brew install python@3.12` (macOS) |

## Related

- [Crawl4AI](../browser/crawl4ai.md) — Web crawling for AI/LLM applications
- [Stagehand](../browser/stagehand.md) — AI-powered browser automation
- [Context7](../context/context7.md) — Library documentation lookup
