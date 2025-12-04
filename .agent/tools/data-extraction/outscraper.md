# Outscraper MCP Server

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Business intelligence extraction from Google Maps, Amazon, reviews, contacts
- **Install**: `pip install outscraper-mcp-server` or `uvx outscraper-mcp-server`
- **Auth**: API key from <https://auth.outscraper.com/profile>
- **Env Var**: `OUTSCRAPER_API_KEY`
- **Docs**: <https://app.outscraper.com/api-docs>

**OpenCode Config**:

```json
"outscraper": {
  "type": "local",
  "command": ["/bin/bash", "-c", "OUTSCRAPER_API_KEY=$OUTSCRAPER_API_KEY uvx outscraper-mcp-server"],
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
  `glassdoor_reviews`, `capterra_reviews`
- Business: `emails_and_contacts`, `phones_enricher`, `company_insights`,
  `email_validation`, `whitepages_data`, `amazon_products`
- Geo: `geocoding`, `reverse_geocoding`

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
| **Reviews** | Amazon, TripAdvisor, Apple Store, YouTube, G2, Trustpilot, Glassdoor, Capterra |
| **Business Intel** | Email extraction, phone validation, company insights |
| **Geolocation** | Address to coordinates, reverse geocoding |

Use cases:

- Local business research and competitive analysis
- Review aggregation and sentiment analysis
- Lead generation with contact enrichment
- Market research across platforms
- Location-based data collection

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
      "command": ["/bin/bash", "-c", "OUTSCRAPER_API_KEY=$OUTSCRAPER_API_KEY uvx outscraper-mcp-server"],
      "enabled": true
    }
  },
  "tools": {
    "outscraper_*": false
  }
}
```

The `@outscraper` subagent is automatically created by `generate-opencode-agents.sh` with:

```json
"tools": {
  "outscraper_*": true
  },
  "Sales": {
    "tools": {
      "outscraper_*": true
    }
  }
}
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
| `google_maps_search` | Search businesses/places with detailed info |
| `google_maps_reviews` | Extract customer reviews from places |
| `google_maps_photos` | Get photos from places |
| `google_maps_directions` | Get directions between locations |

### Search Tools

| Tool | Description |
|------|-------------|
| `google_search` | Organic listings, ads, related data |
| `google_search_news` | Search Google News |

### Review Extraction Tools

| Tool | Description |
|------|-------------|
| `google_play_reviews` | App reviews from Play Store |
| `amazon_reviews` | Product reviews from Amazon |
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
| `phones_enricher` | Validate phones, get carrier data |
| `company_insights` | Company details (revenue, size, etc.) |
| `email_validation` | Validate email deliverability |
| `whitepages_data` | Address/phone owner insights |
| `amazon_products` | Product information from Amazon |

### Geolocation Tools

| Tool | Description |
|------|-------------|
| `geocoding` | Address → coordinates |
| `reverse_geocoding` | Coordinates → address |

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
