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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Crawl4AI Integration Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: #1 AI/LLM web crawler — markdown output for RAG pipelines
- **Helper**: `.agents/scripts/crawl4ai-helper.sh` (`install|docker-setup|docker-start|mcp-setup|capsolver-setup|status|crawl|extract|captcha-crawl`)
- **Docker API**: `http://localhost:11235` (dashboard `/dashboard`, playground `/playground`)
- **Env vars**: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `CAPSOLVER_API_KEY`, `LLM_PROVIDER=openai/gpt-4o-mini`, `CRAWL4AI_MAX_PAGES=50`, `CRAWL4AI_TIMEOUT=60`, `CRAWL4AI_CONCURRENT_REQUESTS=5`

**Capabilities**: LLM-ready markdown, CSS/XPath/LLM extraction, CAPTCHA solving (CapSolver), parallel async crawling (`arun_many` — 1.7x speedup), session management, browser pool, proxy support (HTTP/SOCKS5/residential), persistent context (`user_data_dir`), custom browser engine (Brave/Edge/Chrome via `BrowserConfig`).

**Performance**: Structured extraction 2.5s (30 items), multi-page 3.8s (3 URLs), reliability 0.52s avg. Benchmarked 2026-01-24, macOS ARM64, headless, median of 3 runs. Reproduce via `browser-benchmark.md`.

**Limitations**: No extensions. Limited interaction via `js_code` or C4A-Script DSL (CLICK, TYPE, PRESS). For complex interactive flows, use Playwright.

<!-- AI-CONTEXT-END -->

## Installation

```bash
.agents/scripts/crawl4ai-helper.sh install          # Python package
.agents/scripts/crawl4ai-helper.sh docker-setup      # Docker with monitoring
.agents/scripts/crawl4ai-helper.sh docker-start      # Start container
.agents/scripts/crawl4ai-helper.sh mcp-setup         # MCP integration
.agents/scripts/crawl4ai-helper.sh capsolver-setup   # CAPTCHA solving
```

## CLI Usage

```bash
# Crawl to markdown
.agents/scripts/crawl4ai-helper.sh crawl https://example.com markdown output.json

# Structured extraction
.agents/scripts/crawl4ai-helper.sh extract https://example.com '{"title":"h1","content":".article"}' data.json

# CAPTCHA crawl (requires CAPSOLVER_API_KEY)
.agents/scripts/crawl4ai-helper.sh captcha-crawl https://example.com recaptcha_v2 SITE_KEY
```

## Python API

### Basic Crawl

```python
from crawl4ai import AsyncWebCrawler

async def basic_crawl():
    async with AsyncWebCrawler() as crawler:
        result = await crawler.arun(url="https://example.com")
        return result.markdown
```

### Structured Extraction (CSS)

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
result = await crawler.arun(url="https://shop.com", extraction_strategy=JsonCssExtractionStrategy(schema))
```

### LLM Extraction

```python
from crawl4ai import LLMExtractionStrategy, LLMConfig

llm_strategy = LLMExtractionStrategy(
    llm_config=LLMConfig(provider="openai/gpt-4o"),
    instruction="Extract key information and create a summary"
)
result = await crawler.arun(url="https://article.com", extraction_strategy=llm_strategy)
```

### Browser Hooks

```python
async def setup_hook(page, context, **kwargs):
    await context.route("**/*.{png,jpg,gif}", lambda r: r.abort())
    await page.set_viewport_size({"width": 1920, "height": 1080})
    return page

result = await crawler.arun(url="https://example.com", hooks={"on_page_context_created": setup_hook})
```

### Virtual Scroll

```python
from crawl4ai import VirtualScrollConfig

scroll_config = VirtualScrollConfig(
    container_selector="[data-testid='feed']",
    scroll_count=20, scroll_by="container_height", wait_after_scroll=1.0
)
result = await crawler.arun(url="https://infinite-scroll-site.com", virtual_scroll_config=scroll_config)
```

### Session & Custom Browser

```python
from crawl4ai import AsyncWebCrawler, BrowserConfig

# Persistent session
browser_config = BrowserConfig(use_persistent_context=True, user_data_dir="/path/to/profile", headless=True)
async with AsyncWebCrawler(config=browser_config) as crawler:
    result1 = await crawler.arun("https://site.com/login")
    result2 = await crawler.arun("https://site.com/dashboard")

# Custom engine — Brave (built-in ad blocking), Edge (enterprise SSO), or explicit path
browser_config = BrowserConfig(browser_type="chromium", chrome_channel="brave", headless=True)
# Channels: chrome, msedge, brave, chromium (default). Extensions not supported — use Brave Shields.
```

### Adaptive Crawling

```python
from crawl4ai import AdaptiveCrawler, AdaptiveConfig

config = AdaptiveConfig(confidence_threshold=0.7, max_depth=5, max_pages=20, strategy="statistical")
adaptive_crawler = AdaptiveCrawler(crawler, config)
state = await adaptive_crawler.digest(start_url="https://news.example.com", query="latest technology news")
```

## Docker Deployment

```yaml
services:
  crawl4ai:
    image: unclecode/crawl4ai:latest
    ports: ["11235:11235"]
    environment:
      - OPENAI_API_KEY=${OPENAI_API_KEY}
      - LLM_PROVIDER=openai/gpt-4o-mini
    volumes: ["/dev/shm:/dev/shm"]
    shm_size: 1g
```

Dashboard at `http://localhost:11235/dashboard`: system metrics, browser pool, job queue, real-time logs.

## MCP Integration

Claude Desktop config:

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

**MCP tools**: `crawl_url`, `crawl_multiple`, `extract_structured`, `take_screenshot`, `generate_pdf`, `execute_javascript`, `solve_captcha`, `crawl_with_captcha`, `check_captcha_balance`.

## CAPTCHA Solving (CapSolver)

Supported types: reCAPTCHA v2/v3 (including Enterprise), Cloudflare Turnstile, Cloudflare Challenge, AWS WAF, GeeTest v3/v4, Image-to-Text.

```bash
.agents/scripts/crawl4ai-helper.sh capsolver-setup
export CAPSOLVER_API_KEY="CAP-xxxxxxxxxxxxxxxxxxxxx"
.agents/scripts/crawl4ai-helper.sh captcha-crawl https://example.com recaptcha_v2 site_key_here
```

## Job Queue & Webhooks

```python
import requests

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

## Troubleshooting

```bash
.agents/scripts/crawl4ai-helper.sh status            # Check status
docker run --shm-size=1g unclecode/crawl4ai:latest    # Container won't start — check memory
docker ps | grep crawl4ai                             # API not responding
curl http://localhost:11235/health                     # Health check
docker logs crawl4ai --tail 50 --follow               # View logs
open http://localhost:11235/playground                 # Test extraction in playground
```

```bash
# Verify basic functionality
curl -X POST http://localhost:11235/crawl \
  -H "Content-Type: application/json" \
  -d '{"urls": ["https://httpbin.org/html"]}'
```

## Resources

- **Helper**: `.agents/scripts/crawl4ai-helper.sh`
- **Config template**: `configs/crawl4ai-config.json.txt`
- **MCP config**: `configs/mcp-templates/crawl4ai-mcp-config.json`
- **Docs**: https://docs.crawl4ai.com/
- **GitHub**: https://github.com/unclecode/crawl4ai
- **Docker Hub**: https://hub.docker.com/r/unclecode/crawl4ai
