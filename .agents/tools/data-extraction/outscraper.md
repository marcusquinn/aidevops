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

# Outscraper Data Extraction

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Business intelligence from Google Maps, Amazon, reviews, contacts
- **Auth**: `X-API-KEY` header; key from <https://auth.outscraper.com/profile>
- **Env Var**: `OUTSCRAPER_API_KEY` in `~/.config/aidevops/credentials.sh` (600 perms)
- **API Base**: `https://api.app.outscraper.com` (ignore `api.outscraper.cloud` in OpenAPI spec)
- **Docs**: <https://app.outscraper.com/api-docs>
- **SDK**: <https://github.com/outscraper/outscraper-python>
- **Pricing**: Metered per request — <https://outscraper.com/pricing/> (free tier available)
- **No MCP required** — curl works directly; MCP server available for tool-based access

**MCP Tools** (25+): `google_maps_search`, `google_maps_reviews`, `google_maps_photos`, `google_maps_directions`, `google_search`, `google_search_news`, `google_play_reviews`, `amazon_reviews`, `tripadvisor_reviews`, `apple_store_reviews`, `youtube_comments`, `g2_reviews`, `trustpilot_reviews`, `glassdoor_reviews`, `capterra_reviews`, `yelp_reviews`, `emails_and_contacts`, `contacts_and_leads`, `phones_enricher`, `company_insights`, `email_validation`, `whitepages_phones`, `whitepages_addresses`, `amazon_products`, `company_websites_finder`, `similarweb`, `yelp_search`, `trustpilot_search`, `yellowpages_search`, `geocoding`, `reverse_geocoding`

**Direct API** (not in MCP): `GET /profile/balance`, `GET /invoices`, `POST /tasks`, `GET /webhook-calls`, `GET /locations`

**Verification**: `Search for coffee shops near Times Square NYC using Google Maps search and return the top 5 results with ratings.`

**Tested tools** (Dec 2024): `google_search` — working; `google_maps_search` — working (minor null field warnings, non-blocking)

<!-- AI-CONTEXT-END -->

## Installation & Configuration

**Prerequisites**: Python 3.10+, `uv` recommended

```bash
uvx outscraper-mcp-server          # run via uvx (recommended)
uv add outscraper-mcp-server       # install permanently
pip install outscraper-mcp-server  # or via pip
```

### MCP Server Config

**Claude Desktop / Claude Code**:

```bash
claude mcp add-json outscraper --scope user '{
  "type": "stdio",
  "command": "uvx",
  "args": ["outscraper-mcp-server"],
  "env": {"OUTSCRAPER_API_KEY": "your_api_key_here"}
}'
```

**OpenCode** (`~/.config/opencode/opencode.json`) — `"env"` key not supported, use bash wrapper:

```json
"outscraper": {
  "type": "local",
  "command": ["/bin/bash", "-c", "OUTSCRAPER_API_KEY=$OUTSCRAPER_API_KEY uv tool run outscraper-mcp-server"],
  "enabled": true
}
```

OpenCode access: `@outscraper` subagent only (not enabled for main agents).

**Cursor / Windsurf / Gemini CLI / VS Code / Kilo Code / Kiro** — all use the same pattern:

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

- **Cursor**: Settings → Tools & MCP → New MCP Server
- **Windsurf**: `~/.codeium/windsurf/mcp_config.json`
- **Gemini CLI**: `~/.gemini/settings.json` (user) or `.gemini/settings.json` (project)
- **VS Code**: `.vscode/mcp.json` (use `"type": "stdio"` wrapper)
- **Kilo Code**: MCP server icon → Edit Global MCP (add `"alwaysAllow": ["google_maps_search", "google_search"]`)
- **Kiro**: Cmd+Shift+P → "Kiro: Open user MCP config" (use `"autoApprove"` instead of `"alwaysAllow"`)

**Droid (Factory.AI)**:

```bash
droid mcp add outscraper "uvx" outscraper-mcp-server --env OUTSCRAPER_API_KEY=your_api_key_here
```

**Via Smithery (automatic)**:

```bash
npx -y @smithery/cli install outscraper-mcp-server --client claude
```

## API Reference

| Category | Endpoint | Method | Description |
|----------|----------|--------|-------------|
| **Account** | `/profile/balance` | GET | Balance, status, upcoming invoice |
| | `/invoices` | GET | Invoice history |
| **Tasks** | `/tasks` | GET/POST | UI task history / create task |
| | `/tasks-validate` | POST | Validate/estimate task cost |
| | `/tasks/{id}` | PUT/DELETE | Restart / terminate task |
| **Requests** | `/requests` | GET | Recent API requests (up to 100) |
| | `/requests/{id}` | GET | Async request results |
| | `/webhook-calls` | GET | Failed webhook calls (last 24h) |
| | `/locations` | GET | Country locations for Google Maps |
| **Google** | `/google-search-v3` | GET | Google Search results |
| | `/google-search-news` | GET | Google News search |
| | `/google-maps-search` | POST | Google Maps places (speed-optimized) |
| | `/maps/reviews-v3` | GET | Google Maps reviews (speed-optimized) |
| | `/maps/photos-v3`, `/maps/directions` | GET | Photos, directions |
| | `/google-play/reviews` | GET | Google Play Store reviews |
| **Amazon** | `/amazon/products-v2`, `/amazon/reviews` | GET | Product data and reviews |
| **Reviews** | `/yelp-search`, `/yelp/reviews` | GET | Yelp search and reviews |
| | `/tripadvisor/reviews`, `/appstore/reviews` | GET | Tripadvisor, Apple App Store |
| | `/youtube-comments`, `/g2/reviews` | GET | YouTube comments, G2 reviews |
| | `/trustpilot`, `/trustpilot/reviews` | GET | Trustpilot data and reviews |
| | `/glassdoor/reviews`, `/capterra-reviews` | GET | Glassdoor, Capterra reviews |
| **Business** | `/emails-and-contacts` | GET | Extract emails/contacts from domains |
| | `/contacts-and-leads`, `/phones-enricher` | GET | Contacts with roles, phone validation |
| | `/company-insights`, `/email-validator` | GET | Company data, email deliverability |
| | `/company-website-finder`, `/similarweb` | GET | Website finder, traffic data |
| | `/yellowpages-search` | GET | Yellow Pages search |
| **Geo** | `/geocoding`, `/reverse-geocoding` | GET | Address ↔ coordinates |
| **Whitepages** | `/whitepages-phones`, `/whitepages-addresses` | GET | Phone owner, address/resident lookup |

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
tasks, has_more = client.get_tasks(page_size=1)  # check via SDK
requests.delete(f'{API_BASE}/tasks/{task_id}', headers=headers)  # terminate

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

## Related Documentation

- [Crawl4AI](../browser/crawl4ai.md) — Web crawling for AI/LLM applications
- [Stagehand](../browser/stagehand.md) — AI-powered browser automation
- [Context7](../context/context7.md) — Library documentation lookup
