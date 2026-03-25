---
description: AI-powered web crawling and content extraction
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

# Crawl4AI Integration Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: #1 AI/LLM web crawler - markdown output for RAG pipelines
- **Install**: `./.agents/scripts/crawl4ai-helper.sh install`
- **Docker**: `./.agents/scripts/crawl4ai-helper.sh docker-start`
- **MCP Setup**: `./.agents/scripts/crawl4ai-helper.sh mcp-setup`

**Endpoints** (Docker):
- API: http://localhost:11235
- Dashboard: http://localhost:11235/dashboard
- Playground: http://localhost:11235/playground

**Commands**: `install|docker-setup|docker-start|mcp-setup|capsolver-setup|status|crawl|extract|captcha-crawl`

**Key Features**:
- LLM-ready markdown output
- CSS/XPath/LLM extraction strategies
- CAPTCHA solving via CapSolver
- Parallel async crawling (`arun_many(urls)` — 1.7x speedup over sequential)
- Session management & browser pool
- Full proxy support (HTTP, SOCKS5, residential)
- Persistent context with `user_data_dir`
- Custom browser engine (Brave, Edge, Chrome) via `BrowserConfig`

**Performance**: Structured extraction 2.5s (30 items), multi-page 3.8s (3 URLs), reliability 0.52s avg.
Benchmarked 2026-01-24, macOS ARM64, headless, median of 3 runs. Reproduce via `browser-benchmark.md`.

**Limitations**: No extensions. Limited interaction via `js_code` or C4A-Script DSL (CLICK, TYPE, PRESS). For complex interactive flows, use Playwright.

**Env Vars**: `OPENAI_API_KEY`, `CAPSOLVER_API_KEY`, `CRAWL4AI_MAX_PAGES=50`

<!-- AI-CONTEXT-END -->

## Installation

```bash
# Install Crawl4AI Python package
./.agents/scripts/crawl4ai-helper.sh install

# Setup Docker deployment with monitoring
./.agents/scripts/crawl4ai-helper.sh docker-setup

# Start Docker container
./.agents/scripts/crawl4ai-helper.sh docker-start

# Setup MCP integration for AI assistants
./.agents/scripts/crawl4ai-helper.sh mcp-setup

# Setup CapSolver for CAPTCHA solving
./.agents/scripts/crawl4ai-helper.sh capsolver-setup
```

## Basic Usage

```bash
# Crawl a single URL
./.agents/scripts/crawl4ai-helper.sh crawl https://example.com markdown output.json

# Extract structured data
./.agents/scripts/crawl4ai-helper.sh extract https://example.com '{"title":"h1","content":".article"}' data.json

# Crawl with CAPTCHA solving (requires CapSolver API key)
export CAPSOLVER_API_KEY="CAP-xxxxxxxxxxxxxxxxxxxxx"
./.agents/scripts/crawl4ai-helper.sh captcha-crawl https://example.com recaptcha_v2 6LfW6wATAAAAAHLqO2pb8bDBahxlMxNdo9g947u9
```

## Core Python API

### Web Crawling

```python
import asyncio
from crawl4ai import AsyncWebCrawler

async def basic_crawl():
    async with AsyncWebCrawler() as crawler:
        result = await crawler.arun(url="https://example.com")
        return result.markdown
```

### Structured Data Extraction

```python
from crawl4ai import JsonCssExtractionStrategy

schema = {
    "name": "Product Schema",
    "baseSelector": ".product",
    "fields": [
        {"name": "title", "selector": "h2", "type": "text"},
        {"name": "price", "selector": ".price", "type": "text"},
        {"name": "image", "selector": "img", "type": "attribute", "attribute": "src"}
    ]
}

extraction_strategy = JsonCssExtractionStrategy(schema)
result = await crawler.arun(url="https://shop.com", extraction_strategy=extraction_strategy)
```

### LLM-Powered Extraction

```python
from crawl4ai import LLMExtractionStrategy, LLMConfig

llm_strategy = LLMExtractionStrategy(
    llm_config=LLMConfig(provider="openai/gpt-4o"),
    instruction="Extract key information and create a summary"
)

result = await crawler.arun(url="https://article.com", extraction_strategy=llm_strategy)
```

### Advanced Browser Control

```python
# Custom hooks for advanced control
async def setup_hook(page, context, **kwargs):
    await context.route("**/*.{png,jpg,gif}", lambda r: r.abort())  # Block images
    await page.set_viewport_size({"width": 1920, "height": 1080})
    return page

result = await crawler.arun(url="https://example.com", hooks={"on_page_context_created": setup_hook})
```

### Adaptive Crawling

```python
from crawl4ai import AdaptiveCrawler, AdaptiveConfig

config = AdaptiveConfig(confidence_threshold=0.7, max_depth=5, max_pages=20, strategy="statistical")
adaptive_crawler = AdaptiveCrawler(crawler, config)
state = await adaptive_crawler.digest(start_url="https://news.example.com", query="latest technology news")
```

### Virtual Scroll Support

```python
from crawl4ai import VirtualScrollConfig

scroll_config = VirtualScrollConfig(
    container_selector="[data-testid='feed']",
    scroll_count=20,
    scroll_by="container_height",
    wait_after_scroll=1.0
)
result = await crawler.arun(url="https://infinite-scroll-site.com", virtual_scroll_config=scroll_config)
```

### Session Management

```python
browser_config = BrowserConfig(use_persistent_context=True, user_data_dir="/path/to/profile", headless=True)
async with AsyncWebCrawler(config=browser_config) as crawler:
    result1 = await crawler.arun("https://site.com/login")
    result2 = await crawler.arun("https://site.com/dashboard")
```

### Custom Browser Engine (Brave, Edge, Chrome)

```python
from crawl4ai import AsyncWebCrawler, BrowserConfig

# Brave — built-in ad/tracker blocking via Shields (improves extraction quality)
browser_config = BrowserConfig(browser_type="chromium", chrome_channel="brave", headless=True)

# Edge — enterprise SSO, Azure AD
browser_config = BrowserConfig(browser_type="chromium", chrome_channel="msedge", headless=True)

# Explicit path (any Chromium-based browser)
browser_config = BrowserConfig(
    browser_type="chromium",
    browser_path="/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
    headless=True,
)

async with AsyncWebCrawler(config=browser_config) as crawler:
    result = await crawler.arun(url="https://example.com")
```

**Browser channel values**: `chrome`, `msedge`, `brave`, `chromium` (default). Extensions (uBlock Origin) are not supported — use Brave Shields for equivalent ad blocking.

## Docker Deployment

```yaml
# docker-compose.yml
services:
  crawl4ai:
    image: unclecode/crawl4ai:latest
    ports:
      - "11235:11235"
    environment:
      - OPENAI_API_KEY=${OPENAI_API_KEY}
      - LLM_PROVIDER=openai/gpt-4o-mini
    volumes:
      - /dev/shm:/dev/shm
    shm_size: 1g
```

Dashboard at http://localhost:11235/dashboard: system metrics, browser pool, job queue, real-time logs.

## MCP Integration

Add to Claude Desktop configuration:

```json
{
  "mcpServers": {
    "crawl4ai": {
      "command": "npx",
      "args": ["crawl4ai-mcp-server@latest"],
      "env": { "CRAWL4AI_API_URL": "http://localhost:11235" }
    }
  }
}
```

**Available MCP tools**: `crawl_url`, `crawl_multiple`, `extract_structured`, `take_screenshot`, `generate_pdf`, `execute_javascript`, `solve_captcha`, `crawl_with_captcha`, `check_captcha_balance`.

## CapSolver Integration

Supported CAPTCHA types: reCAPTCHA v2/v3 (including Enterprise), Cloudflare Turnstile, Cloudflare Challenge, AWS WAF, GeeTest v3/v4, Image-to-Text.

```bash
./.agents/scripts/crawl4ai-helper.sh capsolver-setup
export CAPSOLVER_API_KEY="CAP-xxxxxxxxxxxxxxxxxxxxx"
./.agents/scripts/crawl4ai-helper.sh captcha-crawl https://example.com recaptcha_v2 site_key_here
```

## Job Queue & Webhooks

```python
import requests

# Submit async crawl job
response = requests.post("http://localhost:11235/crawl/job", json={
    "urls": ["https://example.com"],
    "webhook_config": {
        "webhook_url": "https://your-app.com/webhook",
        "webhook_data_in_payload": True,
        "webhook_headers": {"X-Webhook-Secret": "your-secret-token"}
    }
})
task_id = response.json()["task_id"]
```

## Configuration

```bash
# Environment variables
OPENAI_API_KEY=sk-your-key
ANTHROPIC_API_KEY=your-anthropic-key
LLM_PROVIDER=openai/gpt-4o-mini
CRAWL4AI_MAX_PAGES=50
CRAWL4AI_TIMEOUT=60
CRAWL4AI_CONCURRENT_REQUESTS=5
```

## Troubleshooting

```bash
# Check status
./.agents/scripts/crawl4ai-helper.sh status

# Container won't start — check memory
docker run --shm-size=1g unclecode/crawl4ai:latest

# API not responding
docker ps | grep crawl4ai
curl http://localhost:11235/health

# View logs
docker logs crawl4ai --tail 50 --follow

# Test basic functionality
curl -X POST http://localhost:11235/crawl \
  -H "Content-Type: application/json" \
  -d '{"urls": ["https://httpbin.org/html"]}'

# Extraction failing — test in playground
open http://localhost:11235/playground
```

## Resources

- **Helper Script**: `.agents/scripts/crawl4ai-helper.sh`
- **Configuration Template**: `configs/crawl4ai-config.json.txt`
- **MCP Configuration**: `configs/mcp-templates/crawl4ai-mcp-config.json`
- **Documentation**: https://docs.crawl4ai.com/
- **GitHub**: https://github.com/unclecode/crawl4ai
- **Docker Hub**: https://hub.docker.com/r/unclecode/crawl4ai
