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

# Outscraper MCP Server

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Business intelligence extraction from Google Maps, Amazon, reviews, contacts
- **Auth**: API key from <https://auth.outscraper.com/profile>
- **Env Var**: `OUTSCRAPER_API_KEY` in `~/.config/aidevops/credentials.sh`
- **API Base**: `https://api.app.outscraper.com`
- **Docs**: <https://app.outscraper.com/api-docs>
- **No MCP required** - uses curl directly

**OpenCode Config**:

```json
"outscraper": {
  "type": "local",
  "command": ["/bin/bash", "-c", "OUTSCRAPER_API_KEY=$OUTSCRAPER_API_KEY uv tool run outscraper-mcp-server"],
  "enabled": true
}
```

**Verification Prompt**:

```text
Search for coffee shops near Times Square NYC using Google Maps search and return the top 5 results with ratings.
```

**MCP Tools** (25+):

- Google Maps: `google_maps_search`, `google_maps_reviews`, `google_maps_photos`, `google_maps_directions`
- Search: `google_search`, `google_search_news`
- Reviews: `google_play_reviews`, `amazon_reviews`, `tripadvisor_reviews`, `apple_store_reviews`, `youtube_comments`, `g2_reviews`, `trustpilot_reviews`, `glassdoor_reviews`, `capterra_reviews`, `yelp_reviews`
- Business: `emails_and_contacts`, `contacts_and_leads`, `phones_enricher`, `company_insights`, `email_validation`, `whitepages_phones`, `whitepages_addresses`, `amazon_products`, `company_websites_finder`, `similarweb`
- Search Platforms: `yelp_search`, `trustpilot_search`, `yellowpages_search`
- Geo: `geocoding`, `reverse_geocoding`

**Direct API** (not in MCP): `GET /profile/balance`, `GET /invoices`, `POST /tasks`, `GET /webhook-calls`, `GET /locations`

**Supported AI Tools**: OpenCode, Claude Code, Cursor, Windsurf, Gemini CLI, VS Code (Copilot), Raycast, custom MCP clients

**OpenCode Access**: `@outscraper` subagent only (not enabled for main agents)

<!-- AI-CONTEXT-END -->

## What It Does

| Category | Capabilities |
|----------|-------------|
| **Google Maps** | Business search, reviews, photos, directions |
| **Search** | Google organic results, news, ads |
| **Reviews** | Amazon, TripAdvisor, Apple Store, YouTube, G2, Trustpilot, Glassdoor, Capterra, Yelp |
| **Business Intel** | Email extraction, phone validation, company insights, contacts & leads |
| **Domain Intel** | Similarweb traffic, company website finder |
| **Directories** | Yellow Pages search, Trustpilot search, Yelp search |
| **Geolocation** | Address to coordinates, reverse geocoding |
| **Whitepages** | Phone identity lookup, address/resident lookup |

Use cases: local business research, review aggregation, lead generation, market research, location-based data collection.

## API Reference

**Base URL**: `https://api.app.outscraper.com` (confirmed from SDK source — ignore `api.outscraper.cloud` in OpenAPI spec)

**Authentication**: API key in `X-API-KEY` header

### Endpoints

| Category | Endpoint | Method | Description |
|----------|----------|--------|-------------|
| **Account** | `/profile/balance` | GET | Balance, status, upcoming invoice |
| | `/invoices` | GET | Invoice history |
| **Tasks** | `/tasks` | GET | UI task history |
| | `/tasks` | POST | Create UI task |
| | `/tasks-validate` | POST | Validate/estimate task cost |
| | `/tasks/{id}` | PUT | Restart task |
| | `/tasks/{id}` | DELETE | Terminate task |
| **Requests** | `/requests` | GET | Recent API requests (up to 100) |
| | `/requests/{id}` | GET | Async request results |
| | `/webhook-calls` | GET | Failed webhook calls (last 24h) |
| | `/locations` | GET | Country locations for Google Maps |
| **Google** | `/google-search-v3` | GET | Google Search results |
| | `/google-search-news` | GET | Google News search |
| | `/google-maps-search` | POST | Google Maps places (speed-optimized) |
| | `/maps/reviews-v3` | GET | Google Maps reviews (speed-optimized) |
| | `/maps/photos-v3` | GET | Google Maps photos |
| | `/maps/directions` | GET | Google Maps directions |
| | `/google-play/reviews` | GET | Google Play Store reviews |
| **Amazon** | `/amazon/products-v2` | GET | Amazon product data |
| | `/amazon/reviews` | GET | Amazon product reviews |
| **Reviews** | `/yelp-search` | GET | Yelp search |
| | `/yelp/reviews` | GET | Yelp reviews |
| | `/tripadvisor/reviews` | GET | Tripadvisor reviews |
| | `/appstore/reviews` | GET | Apple App Store reviews |
| | `/youtube-comments` | GET | YouTube comments |
| | `/g2/reviews` | GET | G2 reviews |
| | `/trustpilot` | GET | Trustpilot business data |
| | `/trustpilot/reviews` | GET | Trustpilot reviews |
| | `/glassdoor/reviews` | GET | Glassdoor reviews |
| | `/capterra-reviews` | GET | Capterra reviews |
| **Business** | `/emails-and-contacts` | GET | Extract emails/contacts from domains |
| | `/contacts-and-leads` | GET | Contacts with roles |
| | `/phones-enricher` | GET | Phone carrier/validation |
| | `/company-insights` | GET | Revenue, size, founding year |
| | `/email-validator` | GET | Email deliverability check |
| | `/company-website-finder` | GET | Find company websites by name |
| | `/similarweb` | GET | Website traffic data |
| | `/yellowpages-search` | GET | Yellow Pages search |
| **Geo** | `/geocoding` | GET | Address → coordinates |
| | `/reverse-geocoding` | GET | Coordinates → address |
| **Whitepages** | `/whitepages-phones` | GET | Phone owner lookup |
| | `/whitepages-addresses` | GET | Address/resident lookup |

### Common Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `query` | string/list | Search query or queries (up to 250) |
| `limit` | int | Maximum results per query |
| `language` | string | Language code (e.g., 'en', 'de', 'es') |
| `region` | string | Country code (e.g., 'US', 'GB', 'CA') |
| `fields` | string/list | Fields to include in response |
| `async` | bool | Submit async and retrieve later |
| `ui` | bool | Execute as UI task |
| `webhook` | string | Callback URL for completion notification |

## Prerequisites

- **Python 3.10+** required
- **uv** recommended for package management
- **Outscraper account** at <https://outscraper.com>

## Installation

```bash
# Install via uvx (recommended)
uvx outscraper-mcp-server

# Or permanently
uv add outscraper-mcp-server

# Or via pip
pip install outscraper-mcp-server
```

### Configure API Key

1. Sign up at <https://outscraper.com>, get key from <https://auth.outscraper.com/profile>
2. Add to `~/.config/aidevops/credentials.sh`:

```bash
export OUTSCRAPER_API_KEY="your_api_key_here"
```

```bash
chmod 600 ~/.config/aidevops/credentials.sh
echo 'source ~/.config/aidevops/credentials.sh' >> ~/.zshrc
```

## AI Tool Configurations

### OpenCode

Edit `~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "outscraper": {
      "type": "local",
      "command": ["/bin/bash", "-c", "OUTSCRAPER_API_KEY=$OUTSCRAPER_API_KEY uv tool run outscraper-mcp-server"],
      "enabled": true
    }
  },
  "tools": {
    "outscraper_*": false
  }
}
```

The `@outscraper` subagent is automatically created by `generate-opencode-agents.sh` with `outscraper_*: true` and `webfetch: true`.

### Claude Desktop / Claude Code

```bash
claude mcp add-json outscraper --scope user '{
  "type": "stdio",
  "command": "uvx",
  "args": ["outscraper-mcp-server"],
  "env": {"OUTSCRAPER_API_KEY": "your_api_key_here"}
}'
```

### Other AI Tools (Cursor, Windsurf, Gemini CLI, VS Code, Kilo Code, Kiro)

All use the same `uvx` pattern — add to the tool's MCP config file:

```json
{
  "mcpServers": {
    "outscraper": {
      "command": "uvx",
      "args": ["outscraper-mcp-server"],
      "env": {
        "OUTSCRAPER_API_KEY": "your_api_key_here"
      }
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

## Python SDK Examples

The official SDK is at <https://github.com/outscraper/outscraper-python>

```python
from outscraper import ApiClient
import requests

# SDK client (recommended for most operations)
client = ApiClient(api_key='YOUR_API_KEY')

# Direct API calls (for endpoints not in SDK)
API_BASE = 'https://api.app.outscraper.com'
headers = {'X-API-KEY': 'YOUR_API_KEY'}
```

### Account & Billing (Direct API Only)

```python
# Balance
response = requests.get(f'{API_BASE}/profile/balance', headers=headers)
balance_info = response.json()

# Invoices
response = requests.get(f'{API_BASE}/invoices', headers=headers)
invoices = response.json()
```

### Task Management

```python
task_data = {"service": "google_maps_search", "query": ["coffee shops manhattan"], "limit": 50}

# Validate first (not in SDK)
response = requests.post(f'{API_BASE}/tasks-validate', headers=headers, json=task_data)
estimate = response.json()  # {"valid": true, "estimated_cost": 5.00, ...}

# Create task (not in SDK)
response = requests.post(f'{API_BASE}/tasks', headers=headers, json=task_data)
task_id = response.json()['id']

# Check via SDK
tasks, has_more = client.get_tasks(page_size=1)

# Terminate (not in SDK)
requests.delete(f'{API_BASE}/tasks/{task_id}', headers=headers)
```

### Request History & Async

```python
# Recent requests
finished = client.get_requests_history(type='finished', page_size=25)
running = client.get_requests_history(type='running')

# Async pattern
results = client.google_maps_search('restaurants brooklyn usa', limit=100, async_request=True)
request_id = results['id']

import time
while True:
    result = client.get_request_archive(request_id)
    if result['status'] != 'Pending':
        break
    time.sleep(5)

data = result.get('data', [])
```

### Webhook Integration

```python
results = client.google_maps_reviews(
    'ChIJrc9T9fpYwokRdvjYRHT8nI4',
    reviews_limit=100,
    async_request=True,
    webhook='https://your-server.com/outscraper-callback'
)
```

## Advanced Features

- **Data Enrichment**: Add `enrichment` parameter to include contact information
- **Multi-Language**: Specify `language` for localized results
- **Pagination**: Use `skip` and `limit` for large result sets
- **Time-Based Filtering**: Filter reviews by date with `cutoff` parameter

## Usage Examples

```text
# Local business research
Search for "plumbers" near "Austin, TX" on Google Maps. For the top 10 results,
get their ratings, review counts, and contact information.

# Competitive review analysis
Get the 50 most recent Trustpilot reviews for "competitor.com" and summarize
the common complaints and praise points.

# Lead generation
Find software companies in the "CRM" space using Google search, then extract
email contacts from their websites.

# Market research
Search for "electric vehicles" on Google News and return the top 20 articles
from the past week with their sources and summaries.
```

## Verification

**Tested tools** (Dec 2024):
- `google_search` - Working perfectly
- `google_maps_search` - Working (minor null field warnings, non-blocking)

## Rate Limits & Pricing

- API usage is metered per request
- Check pricing at <https://outscraper.com/pricing/>
- Consider caching for frequently accessed data
- Free tier available for testing

## Credential Storage

| Method | Location | Use Case |
|--------|----------|----------|
| Environment | `OUTSCRAPER_API_KEY` | Local development, CI/CD |
| aidevops pattern | `~/.config/aidevops/credentials.sh` | Consistent with other services |
| Per-config | `env` block in MCP config | Tool-specific isolation |

**Security**: Never commit API keys. Use environment variables or secure vaults.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `OUTSCRAPER_API_KEY not set` | `export OUTSCRAPER_API_KEY="your_key_here"` |
| `uvx: command not found` | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| Connection refused / timeout | Check key at <https://auth.outscraper.com/profile>; verify connectivity |
| Tool not found | Ensure MCP server enabled; restart AI tool; check agent has `outscraper_*: true` |
| OpenCode `"env"` key not supported | Use bash wrapper: `"command": ["/bin/bash", "-c", "OUTSCRAPER_API_KEY=$OUTSCRAPER_API_KEY uv tool run outscraper-mcp-server"]` |
| `uvx` conflicts | Use `uv tool run outscraper-mcp-server` instead |
| Python version errors | `brew install python@3.12` (macOS) |

## Updates

- Repository: <https://github.com/outscraper/outscraper-mcp>
- PyPI: <https://pypi.org/project/outscraper-mcp-server/>
- API Docs: <https://app.outscraper.com/api-docs>

## Related Documentation

- [Crawl4AI](../browser/crawl4ai.md) - Web crawling for AI/LLM applications
- [Stagehand](../browser/stagehand.md) - AI-powered browser automation
- [Context7](../context/context7.md) - Library documentation lookup
