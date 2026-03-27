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
- **Install path**: `~/.aidevops/watercrawl/`
- **Env vars**: `WATERCRAWL_API_KEY`, `WATERCRAWL_API_URL` (stored in `~/.config/aidevops/credentials.sh`)
- **SDKs**: Node.js (`@watercrawl/nodejs`), Python (`watercrawl-py`), Go, PHP

**Self-Hosted commands**: `docker-setup|docker-start|docker-stop|docker-logs|docker-admin|coolify-deploy`
**API commands**: `setup|status|api-key|api-url|scrape|crawl|search|sitemap|help`

**Self-Hosted endpoints** (default): Frontend `http://localhost` · API `http://localhost/api` · MinIO `http://localhost/minio-console`

**vs Crawl4AI**: WaterCrawl has web search + full web UI; Crawl4AI has CAPTCHA solving + Python-native. Use WaterCrawl for web search and team dashboards; Crawl4AI for CAPTCHA-heavy sites.
**vs Firecrawl**: Similar features. WaterCrawl is fully open-source with self-hosting.

<!-- AI-CONTEXT-END -->

## When to Use

| Use WaterCrawl | Use alternative |
|----------------|-----------------|
| Self-hosted crawling with full control | CAPTCHA solving → Crawl4AI + CapSolver |
| Web search integration for AI agents | Browser automation/interaction → Playwright |
| Team dashboard + API key management | Own browser session → Playwriter |
| Sitemap discovery and LLM-ready markdown | |

## Quick Start — Self-Hosted (Recommended)

```bash
bash .agents/scripts/watercrawl-helper.sh docker-setup    # clone + configure
bash .agents/scripts/watercrawl-helper.sh docker-start    # start services
bash .agents/scripts/watercrawl-helper.sh docker-admin    # create admin user
bash .agents/scripts/watercrawl-helper.sh api-key YOUR_API_KEY

# Coolify (VPS)
bash .agents/scripts/watercrawl-helper.sh coolify-deploy
```

## Quick Start — Cloud API

```bash
bash .agents/scripts/watercrawl-helper.sh setup
bash .agents/scripts/watercrawl-helper.sh api-url https://app.watercrawl.dev
bash .agents/scripts/watercrawl-helper.sh api-key YOUR_API_KEY
bash .agents/scripts/watercrawl-helper.sh status
```

## CLI Usage

```bash
bash .agents/scripts/watercrawl-helper.sh scrape https://example.com
bash .agents/scripts/watercrawl-helper.sh crawl https://docs.example.com 3 100 output.json
bash .agents/scripts/watercrawl-helper.sh search "AI web crawling" 10 results.json
bash .agents/scripts/watercrawl-helper.sh sitemap https://example.com sitemap.json
```

## Node.js SDK

```bash
npm install @watercrawl/nodejs
```

```javascript
import { WaterCrawlAPIClient } from '@watercrawl/nodejs';
const client = new WaterCrawlAPIClient(process.env.WATERCRAWL_API_KEY);

// Scrape
const result = await client.scrapeUrl('https://example.com', {
    only_main_content: true, include_links: true, wait_time: 2000
});

// Crawl with monitoring
const crawlRequest = await client.createCrawlRequest(
    'https://docs.example.com',
    { max_depth: 3, page_limit: 100, allowed_domains: ['docs.example.com'], exclude_paths: ['/api/*'] },
    { only_main_content: true, include_links: true, wait_time: 2000 }
);
for await (const event of client.monitorCrawlRequest(crawlRequest.uuid)) {
    if (event.type === 'state') console.log(`Status: ${event.data.status}, Pages: ${event.data.number_of_documents}`);
    else if (event.type === 'result') console.log(`Crawled: ${event.data.url}`);
}

// Batch crawl
const batchRequest = await client.createBatchCrawlRequest(
    ['https://example.com/page1', 'https://example.com/page2', 'https://example.com/page3'],
    { proxy_server: null },
    { wait_time: 1000, include_html: true }
);
for await (const event of client.monitorCrawlRequest(batchRequest.uuid)) { /* handle events */ }

// Web search
const results = await client.createSearchRequest(
    'AI web crawling frameworks',
    { language: 'en', country: 'us', time_range: 'month', depth: 'advanced' },
    10, true, true  // limit, sync, download
);
for (const r of results) console.log(`${r.title}: ${r.url}\n${r.description}`);

// Sitemap
const sitemap = await client.createSitemapRequest(
    'https://example.com',
    { include_subdomains: true, ignore_sitemap_xml: false, include_paths: [], exclude_paths: ['/admin/*'] },
    true, true  // sync, download
);
const jsonSitemap     = await client.getSitemapResults(sitemap.uuid, 'json');
const markdownSitemap = await client.getSitemapResults(sitemap.uuid, 'markdown');
const graphSitemap    = await client.getSitemapResults(sitemap.uuid, 'graph');
```

## Python SDK

```bash
pip install watercrawl-py
```

```python
from watercrawl import WaterCrawlAPIClient
client = WaterCrawlAPIClient(api_key="your-api-key")

result = client.scrape_url("https://example.com",
    page_options={"only_main_content": True, "include_links": True, "wait_time": 2000})

# Async
import asyncio
from watercrawl import AsyncWaterCrawlAPIClient

async def crawl_site():
    client = AsyncWaterCrawlAPIClient(api_key="your-api-key")
    crawl_request = await client.create_crawl_request(
        url="https://docs.example.com",
        spider_options={"max_depth": 3, "page_limit": 100}
    )
    async for event in client.monitor_crawl_request(crawl_request.uuid):
        if event["type"] == "result":
            print(f"Crawled: {event['data']['url']}")

asyncio.run(crawl_site())
```

## Options Reference

**Page options**:

| Option | Type | Description |
|--------|------|-------------|
| `only_main_content` | boolean | Remove headers/footers/nav |
| `include_links` | boolean | Include discovered links |
| `include_html` | boolean | Include raw HTML |
| `wait_time` | number | ms to wait after page load |
| `timeout` | number | Request timeout in ms |
| `exclude_tags` | string[] | HTML tags to exclude |
| `include_tags` | string[] | HTML tags to whitelist |
| `accept_cookies_selector` | string | CSS selector for cookie button |
| `locale` | string | Browser locale (e.g. `en-US`) |
| `extra_headers` | object | Custom HTTP headers |
| `actions` | Action[] | screenshot, pdf, etc. |

**Spider options**:

| Option | Type | Description |
|--------|------|-------------|
| `max_depth` | number | Max crawl depth from start URL |
| `page_limit` | number | Max pages to crawl |
| `allowed_domains` | string[] | Domains allowed to crawl |
| `exclude_paths` | string[] | URL paths to exclude (glob) |
| `include_paths` | string[] | URL paths to include (glob) |
| `proxy_server` | string | Proxy URL or `'team'` |

## Proxy Integration

```javascript
await client.createCrawlRequest('https://example.com', { proxy_server: 'team' }, {});
await client.createCrawlRequest('https://example.com',
    { proxy_server: 'http://user:pass@proxy.example.com:8080' }, {});
```

Proxy tiers: Free → team proxies only · Startup → datacenter (10+ locations) · Growth+ → residential (40+ locations)

## Self-Hosted (Manual Docker)

```bash
git clone https://github.com/watercrawl/WaterCrawl.git && cd WaterCrawl
cp .env.example .env  # edit with your settings
docker-compose up -d
```

Full guide: https://github.com/watercrawl/WaterCrawl/blob/main/DEPLOYMENT.md

## Plugins

```bash
pip install watercrawl-plugin   # base library for custom plugins
pip install watercrawl-openai   # LLM-powered content extraction
```

## Troubleshooting

```bash
bash .agents/scripts/watercrawl-helper.sh status          # check config
bash .agents/scripts/watercrawl-helper.sh api-key NEW_KEY # reconfigure
curl -H "Authorization: Bearer $WATERCRAWL_API_KEY" https://app.watercrawl.dev/api/v1/core/crawl-requests/
```

**Free tier limits**: 1,000 pages/month · 100 pages/day · max depth 2 · max 50 pages/crawl · 1 concurrent crawl

## Tool Comparison

| Feature | WaterCrawl | Crawl4AI | Firecrawl |
|---------|-----------|----------|-----------|
| Self-hosted | Yes | Yes | No |
| Web search | Yes | No | No |
| CAPTCHA solving | No | Yes (CapSolver) | No |
| Open source | Yes | Yes | Partial |
| Free tier | 1,000 pages/mo | Unlimited | 500 pages/mo |
| Proxy support | Datacenter + residential | Yes | Yes |
| Plugin system | Yes | Yes | No |
| JS rendering | Yes | Yes | Yes |

## Resources

- Dashboard: https://app.watercrawl.dev
- Docs: https://docs.watercrawl.dev
- API reference: https://docs.watercrawl.dev/api/documentation/
- GitHub: https://github.com/watercrawl/WaterCrawl
- Node.js SDK: https://github.com/watercrawl/watercrawl-nodejs
- Python SDK: https://github.com/watercrawl/watercrawl-py
- Discord: https://discord.com/invite/8bwgBWeXYr
