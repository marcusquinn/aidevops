# Outscraper MCP Server

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Business intelligence extraction from Google Maps, Amazon, reviews, contacts
- **Install**: `uv tool run outscraper-mcp-server` or `pip install outscraper-mcp-server`
- **Auth**: API key from <https://auth.outscraper.com/profile>
- **Env Var**: `OUTSCRAPER_API_KEY`
- **API Base**: `https://api.app.outscraper.com`
- **Docs**: <https://app.outscraper.com/api-docs>

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

- Google Maps: `google_maps_search`, `google_maps_reviews`, `google_maps_photos`,
  `google_maps_directions`
- Search: `google_search`, `google_search_news`
- Reviews: `google_play_reviews`, `amazon_reviews`, `tripadvisor_reviews`,
  `apple_store_reviews`, `youtube_comments`, `g2_reviews`, `trustpilot_reviews`,
  `glassdoor_reviews`, `capterra_reviews`, `yelp_reviews`
- Business: `emails_and_contacts`, `contacts_and_leads`, `phones_enricher`,
  `company_insights`, `email_validation`, `whitepages_phones`, `whitepages_addresses`,
  `amazon_products`, `company_websites_finder`, `similarweb`
- Search Platforms: `yelp_search`, `trustpilot_search`, `yellowpages_search`
- Geo: `geocoding`, `reverse_geocoding`

**Direct API** (not in MCP): `GET /profile/balance`, `GET /invoices`,
`POST /tasks`, `GET /webhook-calls`, `GET /locations`

**Supported AI Tools**: OpenCode, Claude Code, Cursor, Windsurf, Gemini CLI,
VS Code (Copilot), Raycast, custom MCP clients

**OpenCode Access**: `@outscraper` subagent only (not enabled for main agents)

<!-- AI-CONTEXT-END -->

## What It Does

Outscraper provides comprehensive data extraction from online platforms:

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

Use cases:

- Local business research and competitive analysis
- Review aggregation and sentiment analysis
- Lead generation with contact enrichment
- Market research across platforms
- Location-based data collection

## Full API Reference

**Base URL**: `https://api.app.outscraper.com`

This is the URL used by the official Python SDK. The OpenAPI spec references
`api.outscraper.cloud` but the SDK source confirms `api.app.outscraper.com`.

**Authentication**: API key in `X-API-KEY` header

### Account & Billing Endpoints

These endpoints are available via direct API calls (not in Python SDK):

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/profile/balance` | GET | Account balance, status, and upcoming invoice |
| `/invoices` | GET | User invoice history |

#### Get Account Balance

```python
import requests

response = requests.get(
    'https://api.app.outscraper.com/profile/balance',
    headers={'X-API-KEY': 'YOUR_API_KEY'}
)
balance_info = response.json()
# Returns: {"balance": 100.00, "account_status": "active", "upcoming_invoice": {...}}
```

#### Get Invoices

```python
response = requests.get(
    'https://api.app.outscraper.com/invoices',
    headers={'X-API-KEY': 'YOUR_API_KEY'}
)
invoices = response.json()
```

### System & Request Endpoints

| Endpoint | Method | In SDK | Description |
|----------|--------|--------|-------------|
| `/tasks` | GET | Yes | Fetch user UI tasks (platform task history) |
| `/tasks` | POST | No | Create a new UI task via API |
| `/tasks-validate` | POST | No | Validate/estimate a task before creation |
| `/tasks/{taskId}` | PUT | No | Restart a task |
| `/tasks/{taskId}` | DELETE | No | Terminate a task |
| `/requests` | GET | Yes | Fetch up to 100 of your last API requests |
| `/requests/{requestId}` | GET | Yes | Fetch request data from archive (async results) |
| `/webhook-calls` | GET | No | Failed webhook calls (last 24 hours) |
| `/locations` | GET | No | Country locations for Google Maps searches |

#### Get UI Tasks

Fetch user UI tasks created through the platform.

```python
from outscraper import ApiClient
client = ApiClient(api_key='YOUR_API_KEY')

# Get tasks with optional filtering
tasks, has_more = client.get_tasks(query='', page_size=10)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `query` | string | Search query/tag to filter tasks |
| `last_id` | string | Last task ID for pagination |
| `page_size` | int | Number of items to return (default: 10) |

#### Create UI Task

Create a task via API (same as creating through the web UI).

```python
import requests

task_data = {
    "service": "google_maps_search",
    "query": ["restaurants brooklyn usa"],
    "limit": 100
}

response = requests.post(
    'https://api.app.outscraper.com/tasks',
    headers={'X-API-KEY': 'YOUR_API_KEY'},
    json=task_data
)
task = response.json()
```

#### Validate/Estimate Task

Validate a task and get cost estimate before creation.

```python
response = requests.post(
    'https://api.app.outscraper.com/tasks-validate',
    headers={'X-API-KEY': 'YOUR_API_KEY'},
    json=task_data
)
validation = response.json()
# Returns: {"valid": true, "estimated_cost": 5.00, ...}
```

#### Restart Task

```python
response = requests.put(
    f'https://api.app.outscraper.com/tasks/{task_id}',
    headers={'X-API-KEY': 'YOUR_API_KEY'}
)
```

#### Terminate Task

```python
response = requests.delete(
    f'https://api.app.outscraper.com/tasks/{task_id}',
    headers={'X-API-KEY': 'YOUR_API_KEY'}
)
```

#### Get Requests History

Fetch your recent API requests (running or finished).

```python
# Get finished requests
requests = client.get_requests_history(type='finished', skip=0, page_size=25)

# Get running requests
running = client.get_requests_history(type='running')
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `type` | string | Filter: `running` or `finished` |
| `skip` | int | Skip first N records (pagination) |
| `page_size` | int | Number of items (default: 25, max: 100) |

#### Get Request Archive

Retrieve results from async requests.

```python
# Get archived request data
result = client.get_request_archive(request_id='your_request_id')
# Returns: {"id": "...", "status": "Pending|Completed|Failed", "data": [...]}
```

#### Get Failed Webhook Calls

Retrieve failed webhook calls from the last 24 hours.

```python
response = requests.get(
    'https://api.app.outscraper.com/webhook-calls',
    headers={'X-API-KEY': 'YOUR_API_KEY'}
)
failed_webhooks = response.json()
```

#### Get Locations

Get available country locations for Google Maps searches.

```python
response = requests.get(
    'https://api.app.outscraper.com/locations',
    headers={'X-API-KEY': 'YOUR_API_KEY'}
)
locations = response.json()
# Returns list of countries with their location codes
```

### Google Services

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/google-search-v3` | GET | Google Search results |
| `/google-search-news` | GET | Google News search |
| `/google-maps-search` | POST | Google Maps places search (speed-optimized) |
| `/maps/search` | GET | Google Maps search (legacy) |
| `/maps/reviews-v3` | GET | Google Maps reviews (speed-optimized) |
| `/maps/reviews-v2` | GET | Google Maps reviews (legacy) |
| `/maps/photos-v3` | GET | Google Maps photos |
| `/maps/directions` | GET | Google Maps directions |
| `/google-play/reviews` | GET | Google Play Store reviews |

### Amazon Services

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/amazon/products-v2` | GET | Amazon product data |
| `/amazon/reviews` | GET | Amazon product reviews |

### Review Platforms

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/yelp-search` | GET | Yelp search results |
| `/yelp/reviews` | GET | Yelp business reviews |
| `/tripadvisor/reviews` | GET | Tripadvisor reviews |
| `/appstore/reviews` | GET | Apple App Store reviews |
| `/youtube-comments` | GET | YouTube video comments |
| `/g2/reviews` | GET | G2 product reviews |
| `/trustpilot` | GET | Trustpilot business data |
| `/trustpilot/reviews` | GET | Trustpilot reviews |
| `/glassdoor/reviews` | GET | Glassdoor company reviews |
| `/capterra-reviews` | GET | Capterra software reviews |

### Business Intelligence

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/emails-and-contacts` | GET | Extract emails/contacts from domains |
| `/contacts-and-leads` | GET | Contacts and leads scraper (with roles) |
| `/phones-enricher` | GET | Phone carrier data/validation |
| `/company-insights` | GET | Company details (revenue, size, etc.) |
| `/email-validator` | GET | Email address verification |
| `/company-website-finder` | GET | Find company websites by name |
| `/similarweb` | GET | Similarweb traffic data |
| `/yellowpages-search` | GET | Yellow Pages search |

### Geolocation

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/geocoding` | GET | Address to coordinates |
| `/reverse-geocoding` | GET | Coordinates to address |

### Whitepages

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/whitepages-phones` | GET | Phone number owner lookup |
| `/whitepages-addresses` | GET | Address/resident lookup |

### Common Parameters

Most endpoints support these parameters:

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

### Account Access via API

The following account features are available via API:

| Feature | Endpoint | Description |
|---------|----------|-------------|
| Balance | `GET /profile/balance` | Current balance, account status |
| Invoices | `GET /invoices` | Invoice history |
| Usage | `GET /requests` | API request history |
| Tasks | `GET /tasks` | UI task history |

For subscription management and detailed analytics, visit <https://app.outscraper.com>

## Prerequisites

- **Python 3.10+** required
- **uv** recommended for package management
- **Outscraper account** at <https://outscraper.com>

Check Python version:

```bash
python3 --version  # Must be 3.10+
```

## Installation

### 1. Install via uvx (Recommended)

```bash
# One-time execution (no installation needed)
uvx outscraper-mcp-server

# Or install permanently
uv add outscraper-mcp-server
```

### 2. Install via pip

```bash
pip install outscraper-mcp-server
```

### 3. Get API Key

1. Sign up at <https://outscraper.com>
2. Get your API key from <https://auth.outscraper.com/profile>

### 4. Configure Environment

Add to `~/.config/aidevops/mcp-env.sh` (create if needed):

```bash
export OUTSCRAPER_API_KEY="your_api_key_here"
```

Set permissions:

```bash
chmod 600 ~/.config/aidevops/mcp-env.sh
```

Source in your shell profile:

```bash
echo 'source ~/.config/aidevops/mcp-env.sh' >> ~/.zshrc
source ~/.zshrc
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

The `@outscraper` subagent is automatically created by `generate-opencode-agents.sh` with:

```yaml
tools:
  outscraper_*: true
  webfetch: true
```

### Claude Desktop / Claude Code

**Via CLI (recommended)**:

```bash
claude mcp add-json outscraper --scope user '{
  "type": "stdio",
  "command": "uvx",
  "args": ["outscraper-mcp-server"],
  "env": {"OUTSCRAPER_API_KEY": "your_api_key_here"}
}'
```

**Via config file** (`~/Library/Application Support/Claude/claude_desktop_config.json`):

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

**Via Smithery (automatic)**:

```bash
npx -y @smithery/cli install outscraper-mcp-server --client claude
```

### Cursor

Go to Settings → Tools & MCP → New MCP Server.

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

### Windsurf

Edit `~/.codeium/windsurf/mcp_config.json`:

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

### Gemini CLI

Edit `~/.gemini/settings.json` (user level) or `.gemini/settings.json` (project):

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

### VS Code (GitHub Copilot)

Create `.vscode/mcp.json` in your project root:

```json
{
  "servers": {
    "outscraper": {
      "type": "stdio",
      "command": "uvx",
      "args": ["outscraper-mcp-server"],
      "env": {
        "OUTSCRAPER_API_KEY": "your_api_key_here"
      }
    }
  }
}
```

### Kilo Code

Click MCP server icon → Edit Global MCP:

```json
{
  "mcpServers": {
    "outscraper": {
      "command": "uvx",
      "args": ["outscraper-mcp-server"],
      "type": "stdio",
      "disabled": false,
      "env": {
        "OUTSCRAPER_API_KEY": "your_api_key_here"
      },
      "alwaysAllow": ["google_maps_search", "google_search"]
    }
  }
}
```

### Kiro

Open command palette (Cmd+Shift+P / Ctrl+Shift+P) → "Kiro: Open user MCP config":

```json
{
  "mcpServers": {
    "outscraper": {
      "command": "uvx",
      "args": ["outscraper-mcp-server"],
      "disabled": false,
      "env": {
        "OUTSCRAPER_API_KEY": "your_api_key_here"
      },
      "autoApprove": ["google_maps_search", "google_search"]
    }
  }
}
```

### Droid (Factory.AI)

Add via CLI:

```bash
droid mcp add outscraper "uvx" outscraper-mcp-server --env OUTSCRAPER_API_KEY=your_api_key_here
```

## Tool Reference

### Google Maps Tools

| Tool | Description |
|------|-------------|
| `google_maps_search` | Search businesses/places with detailed info (speed-optimized) |
| `google_maps_search_v1` | Legacy Google Maps search |
| `google_maps_reviews` | Extract customer reviews (speed-optimized, v3) |
| `google_maps_reviews_v2` | Legacy reviews extraction |
| `google_maps_photos` | Get photos from places |
| `google_maps_directions` | Get directions between locations |

### Search Tools

| Tool | Description |
|------|-------------|
| `google_search` | Organic listings, ads, related data |
| `google_search_news` | Search Google News with date filtering |

### Review Extraction Tools

| Tool | Description |
|------|-------------|
| `google_play_reviews` | App reviews from Play Store |
| `amazon_reviews` | Product reviews from Amazon |
| `yelp_reviews` | Business reviews from Yelp |
| `tripadvisor_reviews` | Business reviews from TripAdvisor |
| `apple_store_reviews` | App reviews from App Store |
| `youtube_comments` | Comments from YouTube videos |
| `g2_reviews` | Product reviews from G2 |
| `trustpilot_reviews` | Business reviews from Trustpilot |
| `glassdoor_reviews` | Company reviews from Glassdoor |
| `capterra_reviews` | Software reviews from Capterra |

### Business Intelligence Tools

| Tool | Description |
|------|-------------|
| `emails_and_contacts` | Extract emails/contacts from websites |
| `contacts_and_leads` | Advanced leads scraper with contact roles |
| `phones_enricher` | Validate phones, get carrier data |
| `company_insights` | Company details (revenue, size, founding year) |
| `validate_emails` | Validate email deliverability |
| `company_websites_finder` | Find company websites by business name |
| `similarweb` | Website traffic and analytics data |
| `amazon_products` | Product information from Amazon |

### Search & Directory Tools

| Tool | Description |
|------|-------------|
| `yelp_search` | Search businesses on Yelp |
| `trustpilot_search` | Search companies on Trustpilot |
| `trustpilot` | Get Trustpilot business data |
| `yellowpages_search` | Search Yellow Pages directory |

### Whitepages Tools

| Tool | Description |
|------|-------------|
| `whitepages_phones` | Phone number owner lookup |
| `whitepages_addresses` | Address/resident insights |

### Geolocation Tools

| Tool | Description |
|------|-------------|
| `geocoding` | Address → coordinates |
| `reverse_geocoding` | Coordinates → address |

### Account & System Tools

| Tool/Endpoint | Description |
|---------------|-------------|
| `GET /profile/balance` | Account balance, status, upcoming invoice |
| `GET /invoices` | User invoice history |
| `get_tasks` / `GET /tasks` | Fetch UI task history |
| `POST /tasks` | Create UI task via API |
| `POST /tasks-validate` | Validate/estimate task before creation |
| `PUT /tasks/{id}` | Restart a task |
| `DELETE /tasks/{id}` | Terminate a task |
| `get_requests_history` / `GET /requests` | View recent API requests |
| `get_request_archive` / `GET /requests/{id}` | Retrieve async request results |
| `GET /webhook-calls` | Failed webhook calls (last 24 hours) |
| `GET /locations` | Country locations for Google Maps |

## Advanced Features

### Data Enrichment

Many tools support an `enrichment` parameter to add contact information:

```text
Search for marketing agencies in San Francisco and enrich with email contacts.
```

### Multi-Language Support

Specify language for localized results:

```text
Search Google Maps for restaurants in Paris, France with reviews in French.
```

### Pagination

Use `skip` and `limit` for large result sets:

```text
Get Amazon reviews for product ASIN B08N5WRWNW, skip first 100, limit to 50.
```

### Time-Based Filtering

Filter reviews by date with `cutoff` parameter:

```text
Get recent Google Maps reviews for "Starbucks NYC" from the last 30 days.
```

## Python SDK Examples

The official SDK is at <https://github.com/outscraper/outscraper-python>

### Basic Initialization

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

These endpoints are not in the Python SDK - use direct requests:

```python
# Get account balance and status
response = requests.get(f'{API_BASE}/profile/balance', headers=headers)
balance_info = response.json()
print(f"Balance: ${balance_info.get('balance', 0):.2f}")
print(f"Status: {balance_info.get('account_status')}")

# Get invoice history
response = requests.get(f'{API_BASE}/invoices', headers=headers)
invoices = response.json()
for invoice in invoices:
    print(f"Invoice {invoice['id']}: ${invoice['amount']}")
```

### Task Management (Direct API + SDK)

```python
# Create a task via API (not in SDK)
task_data = {
    "service": "google_maps_search",
    "query": ["coffee shops manhattan"],
    "limit": 50
}

# Validate first to get cost estimate (not in SDK)
response = requests.post(f'{API_BASE}/tasks-validate', headers=headers, json=task_data)
estimate = response.json()
print(f"Estimated cost: ${estimate.get('estimated_cost', 0):.2f}")

# Create the task (not in SDK)
response = requests.post(f'{API_BASE}/tasks', headers=headers, json=task_data)
task = response.json()
task_id = task['id']

# Check task status via SDK (in SDK)
tasks, has_more = client.get_tasks(page_size=1)

# Terminate task if needed (not in SDK)
requests.delete(f'{API_BASE}/tasks/{task_id}', headers=headers)
```

### System Request Management (SDK Methods)

```python
# Get your UI task history
tasks, has_more = client.get_tasks(query='restaurants', page_size=10)
for task in tasks:
    print(f"Task: {task['id']} - {task.get('status')}")

# Get your recent API requests
finished_requests = client.get_requests_history(type='finished', page_size=25)
running_requests = client.get_requests_history(type='running')

# Retrieve async request results
result = client.get_request_archive(request_id='abc123')
if result['status'] == 'Completed':
    data = result['data']
```

### Async Request Pattern

```python
# Submit async request for large queries
results = client.google_maps_search(
    'restaurants brooklyn usa',
    limit=100,
    async_request=True  # Returns request ID immediately
)
request_id = results['id']

# Poll for results (SDK handles this automatically if async_request=False)
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
# Use webhooks for async notification
results = client.google_maps_reviews(
    'ChIJrc9T9fpYwokRdvjYRHT8nI4',
    reviews_limit=100,
    async_request=True,
    webhook='https://your-server.com/outscraper-callback'
)
# Outscraper will POST results to your webhook URL when complete
```

## Usage Examples

### Local Business Research

```text
Search for "plumbers" near "Austin, TX" on Google Maps. For the top 10 results,
get their ratings, review counts, and contact information.
```

### Competitive Review Analysis

```text
Get the 50 most recent Trustpilot reviews for "competitor.com" and summarize
the common complaints and praise points.
```

### Lead Generation

```text
Find software companies in the "CRM" space using Google search, then extract
email contacts from their websites.
```

### Market Research

```text
Search for "electric vehicles" on Google News and return the top 20 articles
from the past week with their sources and summaries.
```

## Verification

**Tested tools** (Dec 2024):
- `google_search` - Working perfectly
- `google_maps_search` - Working (minor null field warnings, non-blocking)

After configuration, test with this prompt:

```text
Search for coffee shops near Times Square NYC using Google Maps search and
return the top 5 results with ratings.
```

The AI should:

1. Confirm access to Outscraper tools
2. Return business names, addresses, ratings
3. Include review counts and categories

## Rate Limits & Pricing

- API usage is metered per request
- Check pricing at <https://outscraper.com/pricing/>
- Consider caching for frequently accessed data
- Free tier available for testing

## Credential Storage

| Method | Location | Use Case |
|--------|----------|----------|
| Environment | `OUTSCRAPER_API_KEY` | Local development, CI/CD |
| aidevops pattern | `~/.config/aidevops/mcp-env.sh` | Consistent with other services |
| Per-config | `env` block in MCP config | Tool-specific isolation |

**Security**: Never commit API keys. Use environment variables or secure vaults.

## Troubleshooting

### "OUTSCRAPER_API_KEY not set"

```bash
# Verify environment variable
echo $OUTSCRAPER_API_KEY

# Set if missing
export OUTSCRAPER_API_KEY="your_key_here"
```

### "uvx: command not found"

```bash
# Install uv
curl -LsSf https://astral.sh/uv/install.sh | sh

# Or via pip
pip install uv
```

### "Connection refused" or timeout

1. Check API key validity at <https://auth.outscraper.com/profile>
2. Verify internet connectivity
3. Check Outscraper service status

### "Tool not found"

1. Ensure MCP server is enabled in config
2. Restart the AI tool after config changes
3. Check that the agent has `outscraper_*: true`

### OpenCode-specific issues

**"env" key not supported**: OpenCode doesn't support the `env` key in MCP config.
Use the bash wrapper pattern instead:

```json
"command": ["/bin/bash", "-c", "OUTSCRAPER_API_KEY=$OUTSCRAPER_API_KEY uv tool run outscraper-mcp-server"]
```

**"uvx" conflicts**: The `uvx` command may conflict with other packages.
Use `uv tool run outscraper-mcp-server` instead.

### Python version errors

```bash
# Check version
python3 --version

# Install Python 3.10+ if needed
brew install python@3.12  # macOS
```

## Updates

Check for configuration updates at:

- Repository: <https://github.com/outscraper/outscraper-mcp>
- PyPI: <https://pypi.org/project/outscraper-mcp-server/>
- API Docs: <https://app.outscraper.com/api-docs>

## Related Documentation

- [Crawl4AI](../browser/crawl4ai.md) - Web crawling for AI/LLM applications
- [Stagehand](../browser/stagehand.md) - AI-powered browser automation
- [Context7](../context/context7.md) - Library documentation lookup
