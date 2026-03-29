---
description: Crawl4AI MCP server integration setup
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Crawl4AI Integration Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- Install: `./.agents/scripts/crawl4ai-helper.sh install`
- Docker setup/start: `./.agents/scripts/crawl4ai-helper.sh docker-setup && docker-start`
- MCP setup: `./.agents/scripts/crawl4ai-helper.sh mcp-setup`
- Crawl: `./.agents/scripts/crawl4ai-helper.sh crawl URL markdown output.json`
- Extract: `./.agents/scripts/crawl4ai-helper.sh extract URL '{"title":"h1"}' data.json`
- Debug: `./.agents/scripts/crawl4ai-helper.sh status` | `docker logs crawl4ai`
- URLs: Dashboard http://localhost:11235/dashboard | Playground /playground | API :11235
- MCP tools: `crawl_url`, `crawl_multiple`, `extract_structured`, `take_screenshot`, `generate_pdf`, `execute_javascript`
- Config: `configs/crawl4ai-config.json.txt`, `configs/mcp-templates/crawl4ai-mcp-config.json`
- Docs: https://docs.crawl4ai.com/ | https://github.com/unclecode/crawl4ai

<!-- AI-CONTEXT-END -->

## MCP Config (Claude Desktop)

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

## Usage

```bash
# Crawl to markdown
./.agents/scripts/crawl4ai-helper.sh crawl https://example.com markdown output.json

# CSS extraction
./.agents/scripts/crawl4ai-helper.sh extract https://example.com '{"title":"h1","price":".price"}' data.json
```

### LLM Extraction

```python
from crawl4ai import AsyncWebCrawler, LLMExtractionStrategy, LLMConfig

async with AsyncWebCrawler() as crawler:
    result = await crawler.arun(
        url="https://example.com",
        extraction_strategy=LLMExtractionStrategy(
            llm_config=LLMConfig(provider="openai/gpt-4o"),
            instruction="Extract key information and summarize"
        )
    )
```

### Adaptive Crawling

```python
from crawl4ai import AdaptiveCrawler, AdaptiveConfig

config = AdaptiveConfig(confidence_threshold=0.7, max_depth=5, max_pages=20, strategy="statistical")
adaptive_crawler = AdaptiveCrawler(crawler, config)
state = await adaptive_crawler.digest(start_url="https://news.example.com", query="latest tech news")
```

## Configuration

Environment variables (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY` from secure storage):

```bash
LLM_PROVIDER=openai/gpt-4o-mini
CRAWL4AI_MAX_PAGES=50
CRAWL4AI_TIMEOUT=60
CRAWL4AI_DEFAULT_FORMAT=markdown
```

### Browser / Crawler Config

```python
from crawl4ai import BrowserConfig, CrawlerRunConfig, CacheMode

browser_config = BrowserConfig(
    headless=True,
    viewport={"width": 1920, "height": 1080},
    extra_args=["--disable-blink-features=AutomationControlled"]
)

crawler_config = CrawlerRunConfig(
    cache_mode=CacheMode.ENABLED,
    max_depth=3,
    delay_between_requests=1.0,
    respect_robots_txt=True
)
```

## Monitoring

- Dashboard: http://localhost:11235/dashboard (metrics, browser pool, request analytics)
- Health: `curl http://localhost:11235/health`
- Prometheus: `curl http://localhost:11235/metrics`

## Advanced Features

| Feature | Key param |
|---------|-----------|
| Virtual scroll | `VirtualScrollConfig(container_selector, scroll_count, scroll_by)` |
| Persistent sessions | `BrowserConfig(use_persistent_context=True, user_data_dir="/path")` |
| Proxy | `BrowserConfig(proxy={"server": "...", "username": "...", "password": "..."})` |
| Browser hooks | `crawler.arun(hooks={"on_page_context_created": setup_hook})` |
| Async job queue | `POST http://localhost:11235/crawl/job` with `webhook_config` |

## Security

- Rate limiting: configure `rate_limiting.default_limit` in deployment config
- Hook security: never trust user-provided hook code; validate, sandbox, and timeout all hooks
- Security headers: set `x_content_type_options`, `x_frame_options`, `content_security_policy`

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Browser not starting | Check Docker `--shm-size=1g` |
| API not responding | Verify container running, port accessible |
| Extraction failing | Validate CSS selectors or LLM config |
| Memory issues | Adjust browser pool size and cleanup intervals |
