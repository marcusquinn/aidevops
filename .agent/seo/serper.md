---
description: Serper MCP for Google Search API integration
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
---

# Serper MCP Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Google Search results via Serper API
- **MCP Package**: `serper-mcp-server` (Python, community)
- **Auth**: API Key (stored in `~/.config/aidevops/mcp-env.sh`)
- **Env Var**: `SERPER_API_KEY`
- **API Dashboard**: https://serper.dev/
- **GitHub**: https://github.com/garylab/serper-mcp-server

**Available Tools**:

| Tool | Purpose |
|------|---------|
| `google_search` | Web search results |
| `google_search_images` | Image search results |
| `google_search_videos` | Video search results |
| `google_search_places` | Local business/place search |
| `google_search_maps` | Map search results |
| `google_search_reviews` | Business reviews |
| `google_search_news` | News search results |
| `google_search_shopping` | Shopping/product search |
| `google_search_lens` | Visual search (Google Lens) |
| `google_search_scholar` | Academic/scholarly search |
| `google_search_patents` | Patent search |
| `google_search_autocomplete` | Search suggestions |
| `webpage_scrape` | Scrape webpage content |

<!-- AI-CONTEXT-END -->

## Installation

### Via setup.sh (Recommended)

The aidevops `setup.sh` script automatically configures the Serper MCP server.

### Manual Installation

```bash
# Using uv (recommended)
uvx serper-mcp-server

# Using pip
pip install serper-mcp-server

# Or install globally
pip3 install serper-mcp-server
```text

## Configuration

### Store Credentials

```bash
# Using the secure key management script
bash ~/.aidevops/agents/scripts/setup-local-api-keys.sh set SERPER_API_KEY "your_api_key"
```text

### OpenCode Configuration

Add to `~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "serper": {
      "type": "local",
      "command": [
        "/bin/bash",
        "-c",
        "source ~/.config/aidevops/mcp-env.sh && SERPER_API_KEY=$SERPER_API_KEY uvx serper-mcp-server"
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
    "serper": {
      "command": "uvx",
      "args": ["serper-mcp-server"],
      "env": {
        "SERPER_API_KEY": "your_api_key"
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
    "serper": {
      "command": "uvx",
      "args": ["serper-mcp-server"],
      "env": {
        "SERPER_API_KEY": "your_api_key"
      }
    }
  }
}
```text

### Alternative: Using pip

If you prefer pip over uv:

```json
{
  "mcpServers": {
    "serper": {
      "command": "python3",
      "args": ["-m", "serper_mcp_server"],
      "env": {
        "SERPER_API_KEY": "your_api_key"
      }
    }
  }
}
```text

## Usage Examples

### Web Search

```javascript
// Basic Google search
await serper.google_search({
  q: "best seo tools 2024",
  gl: "us",  // Country code
  hl: "en",  // Language
  num: 10    // Number of results
});
```text

### Image Search

```javascript
// Search for images
await serper.google_search_images({
  q: "seo infographic",
  gl: "us",
  num: 20
});
```text

### News Search

```javascript
// Get latest news
await serper.google_search_news({
  q: "google algorithm update",
  gl: "us",
  tbs: "qdr:w"  // Past week
});
```text

### Local/Places Search

```javascript
// Find local businesses
await serper.google_search_places({
  q: "seo agency",
  location: "New York, NY"
});
```text

### Shopping Search

```javascript
// Product search
await serper.google_search_shopping({
  q: "seo software",
  gl: "us"
});
```text

### Scholar Search

```javascript
// Academic papers
await serper.google_search_scholar({
  q: "search engine optimization research",
  num: 10
});
```text

### Webpage Scraping

```javascript
// Scrape a webpage
await serper.webpage_scrape({
  url: "https://example.com/article"
});
```text

## Search Parameters

Common parameters for all search tools:

| Parameter | Description | Example |
|-----------|-------------|---------|
| `q` | Search query | `"seo tools"` |
| `gl` | Country code | `"us"`, `"uk"`, `"de"` |
| `hl` | Language code | `"en"`, `"es"`, `"fr"` |
| `num` | Number of results | `10`, `20`, `100` |
| `page` | Page number | `1`, `2`, `3` |
| `tbs` | Time filter | `"qdr:d"` (day), `"qdr:w"` (week), `"qdr:m"` (month) |

## Verification

Test the integration:

```text
Use the Serper MCP to search for "best seo tools 2024" in the United States
```text

Expected: Google search results with titles, URLs, snippets, and related data.

## Debugging

```bash
# Using MCP inspector with uvx
npx @modelcontextprotocol/inspector uvx serper-mcp-server

# Or with local development
git clone https://github.com/garylab/serper-mcp-server.git
cd serper-mcp-server
npx @modelcontextprotocol/inspector uv run serper-mcp-server -e SERPER_API_KEY=your_key
```text

## Comparison with DataForSEO

| Feature | Serper | DataForSEO |
|---------|--------|------------|
| **Focus** | Google Search API | Comprehensive SEO data |
| **SERP Data** | Yes | Yes |
| **Keyword Research** | No | Yes |
| **Backlinks** | No | Yes |
| **On-Page Analysis** | No | Yes |
| **Pricing** | Pay-per-search | Subscription |
| **Best For** | Quick searches | Full SEO workflows |

Use Serper for quick Google searches; use DataForSEO for comprehensive SEO analysis.

## Resources

- **API Dashboard**: https://serper.dev/
- **GitHub**: https://github.com/garylab/serper-mcp-server
- **PyPI**: https://pypi.org/project/serper-mcp-server/
- **API Docs**: https://serper.dev/docs
