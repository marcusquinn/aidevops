---
description: WaterCrawl - Modern web crawling for LLM-ready data
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# WaterCrawl Integration Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Transform web content into LLM-ready structured data
- **Type**: Open-source, self-hosted first (Docker/Coolify), cloud API fallback
- **Self-Hosted**: `bash .agents/scripts/watercrawl-helper.sh docker-setup`
- **Cloud API**: `bash .agents/scripts/watercrawl-helper.sh api-url https://app.watercrawl.dev`

**Self-Hosted Commands**: `docker-setup|docker-start|docker-stop|docker-logs|docker-admin|coolify-deploy`
**API Commands**: `setup|status|api-key|api-url|scrape|crawl|search|sitemap|help`

**Key Features**:
- Smart crawling with depth/domain/path controls
- Web search engine integration (real-time web search)
- Sitemap generation and analysis
- JavaScript rendering with wait times
- AI-powered content processing (OpenAI integration)
- Extensible plugin system
- Proxy support (datacenter + residential)

**Self-Hosted Endpoints** (default):
- Frontend: http://localhost
- API: http://localhost/api
- MinIO Console: http://localhost/minio-console

**Installation Path**: `~/.aidevops/watercrawl/`

**SDKs**: Node.js (`@watercrawl/nodejs`), Python (`watercrawl-py`), Go, PHP

**Env Vars**: `WATERCRAWL_API_KEY`, `WATERCRAWL_API_URL` (stored in `~/.config/aidevops/mcp-env.sh`)

**vs Crawl4AI**: Both self-hostable. WaterCrawl has web search + full web UI; Crawl4AI has CAPTCHA solving + Python-native. Use WaterCrawl for web search and team dashboards. Use Crawl4AI for CAPTCHA-heavy sites.

**vs Firecrawl**: Similar features. WaterCrawl is fully open-source with self-hosting.
<!-- AI-CONTEXT-END -->

## Overview

WaterCrawl is a modern web crawling framework that transforms web content into structured, LLM-ready data. It provides smart crawling controls, web search integration, and AI-powered content processing.

**Self-Hosted First**: This integration prioritizes self-hosted deployment via Docker or Coolify over the cloud API. Self-hosting gives you unlimited crawling, full control, and no per-page costs.

### Key Capabilities

| Feature | Description |
|---------|-------------|
| **Smart Crawling** | Depth, domain, and path controls for targeted extraction |
| **Web Search** | Real-time web search with language/country/time filters |
| **Sitemap Generation** | Automatic URL discovery and structure mapping |
| **JavaScript Rendering** | Full browser rendering with configurable wait times |
| **AI Processing** | Built-in OpenAI integration for content transformation |
| **Plugin System** | Extensible architecture for custom processing |
| **Proxy Support** | Datacenter and residential proxy integration |
| **Team Dashboard** | Full web UI for managing crawls and API keys |

### When to Use WaterCrawl

**Best for**:
- Self-hosted web crawling with full control
- Web search integration for AI agents
- Teams needing a dashboard and API key management
- Sitemap discovery and analysis
- LLM-ready markdown output

**Consider alternatives when**:
- CAPTCHA solving required (use Crawl4AI + CapSolver)
- Browser automation/interaction needed (use Playwright)
- Need to use your own browser session (use Playwriter)

## Quick Start (Self-Hosted - RECOMMENDED)

### Docker Deployment

```bash
# Clone and configure WaterCrawl
bash .agents/scripts/watercrawl-helper.sh docker-setup

# Start services
bash .agents/scripts/watercrawl-helper.sh docker-start

# Create admin user
bash .agents/scripts/watercrawl-helper.sh docker-admin

# Access dashboard at http://localhost
# Get API key from dashboard, then:
bash .agents/scripts/watercrawl-helper.sh api-key YOUR_API_KEY

# Test crawling
bash .agents/scripts/watercrawl-helper.sh scrape https://example.com
```

### Coolify Deployment

For VPS deployment via Coolify (self-hosted PaaS):

```bash
bash .agents/scripts/watercrawl-helper.sh coolify-deploy
```

This shows instructions for deploying WaterCrawl as a Docker Compose application in Coolify.

## Quick Start (Cloud API)

If you prefer the managed cloud service:

```bash
# Install SDK
bash .agents/scripts/watercrawl-helper.sh setup

# Point to cloud API
bash .agents/scripts/watercrawl-helper.sh api-url https://app.watercrawl.dev

# Configure API key (get from https://app.watercrawl.dev)
bash .agents/scripts/watercrawl-helper.sh api-key YOUR_API_KEY

# Check status
bash .agents/scripts/watercrawl-helper.sh status
```

### Basic Usage

```bash
# Scrape a single URL
bash .agents/scripts/watercrawl-helper.sh scrape https://example.com

# Crawl a website (depth 3, max 100 pages)
bash .agents/scripts/watercrawl-helper.sh crawl https://docs.example.com 3 100 output.json

# Search the web
bash .agents/scripts/watercrawl-helper.sh search "AI web crawling" 10 results.json

# Generate sitemap
bash .agents/scripts/watercrawl-helper.sh sitemap https://example.com sitemap.json
```

## Node.js SDK Usage

### Installation

```bash
npm install @watercrawl/nodejs
```

### Basic Scraping

```javascript
import { WaterCrawlAPIClient } from '@watercrawl/nodejs';

const client = new WaterCrawlAPIClient(process.env.WATERCRAWL_API_KEY);

// Simple URL scraping
const result = await client.scrapeUrl('https://example.com', {
    only_main_content: true,
    include_links: true,
    wait_time: 2000
});

console.log(result);
```

### Crawling with Monitoring

```javascript
import { WaterCrawlAPIClient } from '@watercrawl/nodejs';

const client = new WaterCrawlAPIClient(process.env.WATERCRAWL_API_KEY);

// Create crawl request
const crawlRequest = await client.createCrawlRequest(
    'https://docs.example.com',
    {
        max_depth: 3,
        page_limit: 100,
        allowed_domains: ['docs.example.com'],
        exclude_paths: ['/api/*', '/admin/*']
    },
    {
        only_main_content: true,
        include_links: true,
        wait_time: 2000
    }
);

console.log(`Crawl started: ${crawlRequest.uuid}`);

// Monitor progress with real-time events
for await (const event of client.monitorCrawlRequest(crawlRequest.uuid)) {
    if (event.type === 'state') {
        console.log(`Status: ${event.data.status}, Pages: ${event.data.number_of_documents}`);
    } else if (event.type === 'result') {
        console.log(`Crawled: ${event.data.url}`);
        // Process event.data.result (markdown content)
    }
}
```

### Batch Crawling

```javascript
// Crawl multiple URLs in a single request
const batchRequest = await client.createBatchCrawlRequest(
    [
        'https://example.com/page1',
        'https://example.com/page2',
        'https://example.com/page3'
    ],
    { proxy_server: null },
    { wait_time: 1000, include_html: true }
);

// Monitor same as regular crawl
for await (const event of client.monitorCrawlRequest(batchRequest.uuid)) {
    // Handle events
}
```

### Web Search

```javascript
// Search the web
const results = await client.createSearchRequest(
    'AI web crawling frameworks',
    {
        language: 'en',
        country: 'us',
        time_range: 'month',  // any, hour, day, week, month, year
        depth: 'advanced'      // basic, advanced, ultimate
    },
    10,    // result limit
    true,  // sync (wait for results)
    true   // download results
);

for (const result of results) {
    console.log(`${result.title}: ${result.url}`);
    console.log(result.description);
}
```

### Sitemap Generation

```javascript
// Generate sitemap
const sitemap = await client.createSitemapRequest(
    'https://example.com',
    {
        include_subdomains: true,
        ignore_sitemap_xml: false,
        include_paths: [],
        exclude_paths: ['/admin/*']
    },
    true,  // sync
    true   // download
);

// Get in different formats
const jsonSitemap = await client.getSitemapResults(sitemap.uuid, 'json');
const markdownSitemap = await client.getSitemapResults(sitemap.uuid, 'markdown');
const graphSitemap = await client.getSitemapResults(sitemap.uuid, 'graph');
```

## Python SDK Usage

### Installation

```bash
pip install watercrawl-py
```

### Basic Usage

```python
from watercrawl import WaterCrawlAPIClient

client = WaterCrawlAPIClient(api_key="your-api-key")

# Simple scrape
result = client.scrape_url(
    "https://example.com",
    page_options={
        "only_main_content": True,
        "include_links": True,
        "wait_time": 2000
    }
)

print(result)
```

### Async Crawling

```python
import asyncio
from watercrawl import AsyncWaterCrawlAPIClient

async def crawl_site():
    client = AsyncWaterCrawlAPIClient(api_key="your-api-key")
    
    crawl_request = await client.create_crawl_request(
        url="https://docs.example.com",
        spider_options={
            "max_depth": 3,
            "page_limit": 100
        }
    )
    
    async for event in client.monitor_crawl_request(crawl_request.uuid):
        if event["type"] == "result":
            print(f"Crawled: {event['data']['url']}")

asyncio.run(crawl_site())
```

## Page Options Reference

| Option | Type | Description |
|--------|------|-------------|
| `exclude_tags` | string[] | HTML tags to exclude from extraction |
| `include_tags` | string[] | HTML tags to include (whitelist) |
| `wait_time` | number | Wait time in ms after page load |
| `only_main_content` | boolean | Extract only main content (remove headers/footers) |
| `include_html` | boolean | Include raw HTML in result |
| `include_links` | boolean | Include discovered links |
| `timeout` | number | Request timeout in ms |
| `accept_cookies_selector` | string | CSS selector for cookie accept button |
| `locale` | string | Browser locale (e.g., "en-US") |
| `extra_headers` | object | Custom HTTP headers |
| `actions` | Action[] | Actions to perform (screenshot, pdf) |

## Spider Options Reference

| Option | Type | Description |
|--------|------|-------------|
| `max_depth` | number | Maximum crawl depth from start URL |
| `page_limit` | number | Maximum pages to crawl |
| `allowed_domains` | string[] | Domains allowed to crawl |
| `exclude_paths` | string[] | URL paths to exclude (glob patterns) |
| `include_paths` | string[] | URL paths to include (glob patterns) |
| `proxy_server` | string | Proxy server URL |

## Proxy Integration

WaterCrawl supports both datacenter and residential proxies:

```javascript
// Using team proxies (configured in dashboard)
const crawlRequest = await client.createCrawlRequest(
    'https://example.com',
    { proxy_server: 'team' },  // Use team proxy list
    {}
);

// Using custom proxy
const crawlRequest = await client.createCrawlRequest(
    'https://example.com',
    { proxy_server: 'http://user:pass@proxy.example.com:8080' },
    {}
);
```

**Proxy tiers by plan**:
- Free: Team proxies only
- Startup: Datacenter proxies (10+ locations)
- Growth+: Premium residential proxies (40+ locations)

## Self-Hosted Deployment

WaterCrawl can be self-hosted using Docker:

```bash
# Clone repository
git clone https://github.com/watercrawl/WaterCrawl.git
cd WaterCrawl

# Configure environment
cp .env.example .env
# Edit .env with your settings

# Start with Docker Compose
docker-compose up -d
```

See [DEPLOYMENT.md](https://github.com/watercrawl/WaterCrawl/blob/main/DEPLOYMENT.md) for full self-hosting guide.

## Plugin System

WaterCrawl supports custom plugins for content processing:

```python
# Install plugin base
pip install watercrawl-plugin

# Example: OpenAI content extraction
pip install watercrawl-openai
```

**Available plugins**:
- `watercrawl-openai`: LLM-powered content extraction
- `watercrawl-plugin`: Base library for custom plugins

## Comparison with Other Tools

| Feature | WaterCrawl | Crawl4AI | Firecrawl |
|---------|-----------|----------|-----------|
| **Type** | Cloud API + Self-host | Self-hosted | Cloud API |
| **Web Search** | Yes | No | No |
| **CAPTCHA Solving** | No | Yes (CapSolver) | No |
| **Open Source** | Yes | Yes | Partial |
| **Free Tier** | 1,000 pages/month | Unlimited | 500 pages/month |
| **Proxy Support** | Yes (datacenter + residential) | Yes | Yes |
| **Plugin System** | Yes | Yes | No |
| **JavaScript Rendering** | Yes | Yes | Yes |

**Choose WaterCrawl when**:
- You need web search integration
- You want a managed cloud service
- You need quick API access without infrastructure
- You want the option to self-host later

**Choose Crawl4AI when**:
- You need high-volume local crawling
- You need CAPTCHA solving
- You want full control over the crawler
- You're building a RAG pipeline

## Troubleshooting

### API Key Issues

```bash
# Check if key is configured
bash .agents/scripts/watercrawl-helper.sh status

# Reconfigure key
bash .agents/scripts/watercrawl-helper.sh api-key YOUR_NEW_KEY
```

### Rate Limiting

Free tier limits:
- 1,000 pages/month
- 100 pages/day
- Max depth: 2
- Max pages per crawl: 50
- 1 concurrent crawl

Upgrade at https://app.watercrawl.dev for higher limits.

### Connection Issues

```bash
# Test API connectivity
curl -H "Authorization: Bearer $WATERCRAWL_API_KEY" \
  https://app.watercrawl.dev/api/v1/core/crawl-requests/
```

## Resources

- **Dashboard**: https://app.watercrawl.dev
- **Documentation**: https://docs.watercrawl.dev
- **API Reference**: https://docs.watercrawl.dev/api/documentation/
- **GitHub**: https://github.com/watercrawl/WaterCrawl
- **Node.js SDK**: https://github.com/watercrawl/watercrawl-nodejs
- **Python SDK**: https://github.com/watercrawl/watercrawl-py
- **Discord**: https://discord.com/invite/8bwgBWeXYr
