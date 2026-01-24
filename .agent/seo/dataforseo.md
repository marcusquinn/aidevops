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

# DataForSEO Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Comprehensive SEO data via DataForSEO APIs
- **API**: REST at `https://api.dataforseo.com/v3/`
- **Auth**: Basic auth (username:password) in `~/.config/aidevops/mcp-env.sh`
- **Env Vars**: `DATAFORSEO_USERNAME`, `DATAFORSEO_PASSWORD`
- **Docs**: https://docs.dataforseo.com/v3/
- **No MCP required** - uses curl directly

**Available Modules**:

| Module | Purpose |
|--------|---------|
| `SERP` | Real-time SERP data for Google, Bing, Yahoo |
| `KEYWORDS_DATA` | Keyword research, search volume, CPC |
| `ONPAGE` | Website crawling, on-page SEO metrics |
| `DATAFORSEO_LABS` | Keywords, SERPs, domains from proprietary databases |
| `BACKLINKS` | Backlink analysis, referring domains, anchor text |
| `BUSINESS_DATA` | Business reviews (Google, Trustpilot, Tripadvisor) |
| `DOMAIN_ANALYTICS` | Website traffic, technologies, Whois |
| `CONTENT_ANALYSIS` | Brand monitoring, sentiment analysis |
| `AI_OPTIMIZATION` | Keyword discovery, LLM benchmarking |

<!-- AI-CONTEXT-END -->

## Direct API Access

```bash
source ~/.config/aidevops/mcp-env.sh
export DFS_AUTH=$(echo -n "$DATAFORSEO_USERNAME:$DATAFORSEO_PASSWORD" | base64)
```

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
# Start crawl task
curl -s -X POST "https://api.dataforseo.com/v3/on_page/task_post" \
  -H "Authorization: Basic $DFS_AUTH" \
  -H "Content-Type: application/json" \
  -d '[{"target": "example.com", "max_crawl_pages": 100}]'
```

## Installation (MCP alternative)

### Via setup.sh (Recommended)

The aidevops `setup.sh` script automatically configures the DataForSEO MCP server.

### Manual Installation

```bash
# Install globally
npm install -g dataforseo-mcp-server

# Or run via npx (no install needed)
npx dataforseo-mcp-server
```text

## Configuration

### Store Credentials

```bash
# Using the secure key management script
bash ~/.aidevops/agents/scripts/setup-local-api-keys.sh set DATAFORSEO_USERNAME "your_username"
bash ~/.aidevops/agents/scripts/setup-local-api-keys.sh set DATAFORSEO_PASSWORD "your_password"
```text

### OpenCode Configuration

Add to `~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "dataforseo": {
      "type": "local",
      "command": [
        "/bin/bash",
        "-c",
        "source ~/.config/aidevops/mcp-env.sh && DATAFORSEO_USERNAME=$DATAFORSEO_USERNAME DATAFORSEO_PASSWORD=$DATAFORSEO_PASSWORD npx dataforseo-mcp-server"
      ],
      "enabled": true
    }
  }
}
```text

### Claude Desktop Configuration

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "dataforseo": {
      "command": "npx",
      "args": ["dataforseo-mcp-server"],
      "env": {
        "DATAFORSEO_USERNAME": "your_username",
        "DATAFORSEO_PASSWORD": "your_password"
      }
    }
  }
}
```text

### Cursor Configuration

Add to `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "dataforseo": {
      "command": "npx",
      "args": ["dataforseo-mcp-server"],
      "env": {
        "DATAFORSEO_USERNAME": "your_username",
        "DATAFORSEO_PASSWORD": "your_password"
      }
    }
  }
}
```text

## Environment Variables

```bash
# Required
export DATAFORSEO_USERNAME="your_username"
export DATAFORSEO_PASSWORD="your_password"

# Optional - Enable specific modules only
export ENABLED_MODULES="SERP,KEYWORDS_DATA,BACKLINKS,DATAFORSEO_LABS"

# Optional - Return full API responses (default: false for concise output)
export DATAFORSEO_FULL_RESPONSE="false"

# Optional - Use simplified filter schema for ChatGPT compatibility
export DATAFORSEO_SIMPLE_FILTER="false"
```text

## Usage Examples

### SERP Analysis

```javascript
// Get real-time SERP data for a keyword
await dataforseo.serp({
  keyword: "best seo tools",
  location_code: 2840, // United States
  language_code: "en",
  device: "desktop"
});
```text

### Keyword Research

```javascript
// Get keyword data with search volume and CPC
await dataforseo.keywords_data({
  keywords: ["seo tools", "keyword research", "backlink checker"],
  location_code: 2840,
  language_code: "en"
});
```text

### Backlink Analysis

```javascript
// Analyze backlinks for a domain
await dataforseo.backlinks({
  target: "example.com",
  mode: "as_is",
  limit: 100
});
```text

### On-Page SEO Audit

```javascript
// Crawl and analyze a website
await dataforseo.onpage({
  target: "https://example.com",
  max_crawl_pages: 100,
  load_resources: true
});
```text

### Domain Analytics

```javascript
// Get domain traffic and technology data
await dataforseo.domain_analytics({
  target: "example.com",
  include_technologies: true
});
```text

## Verification

Test the integration:

```text
Use the DataForSEO MCP to get SERP data for "best seo tools" in the United States
```text

Expected: Search results with rankings, URLs, snippets, and related data.

## Resources

- **Official Docs**: https://docs.dataforseo.com/v3/
- **MCP Server GitHub**: https://github.com/dataforseo/mcp-server-typescript
- **npm Package**: https://www.npmjs.com/package/dataforseo-mcp-server
- **API Dashboard**: https://app.dataforseo.com/
