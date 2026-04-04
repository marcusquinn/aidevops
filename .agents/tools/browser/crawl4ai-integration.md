---
description: Crawl4AI MCP server integration setup
mode: subagent
tools:
  read: true
  bash: true
  grep: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Crawl4AI Integration Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Install**: `./.agents/scripts/crawl4ai-helper.sh install`
- **Docker**: `./.agents/scripts/crawl4ai-helper.sh docker-setup && docker-start`
- **MCP**: `./.agents/scripts/crawl4ai-helper.sh mcp-setup`
- **Crawl**: `./.agents/scripts/crawl4ai-helper.sh crawl URL markdown output.json`
- **Extract**: `./.agents/scripts/crawl4ai-helper.sh extract URL '{"title":"h1"}' data.json`
- **Status**: `./.agents/scripts/crawl4ai-helper.sh status` | `docker logs crawl4ai`
- **Tools**: `crawl_url`, `crawl_multiple`, `extract_structured`, `take_screenshot`, `generate_pdf`, `execute_javascript`
- **Config**: `configs/crawl4ai-config.json.txt`, `configs/mcp-templates/crawl4ai-mcp-config.json`
- **Endpoints**: Dashboard http://localhost:11235/dashboard | Health `/health` | Metrics `/metrics`
- **Docs**: https://docs.crawl4ai.com/ | https://github.com/unclecode/crawl4ai
- **Env**: `LLM_PROVIDER=openai/gpt-4o-mini`, `CRAWL4AI_MAX_PAGES=50`, `CRAWL4AI_TIMEOUT=60`, `CRAWL4AI_DEFAULT_FORMAT=markdown`
- **Secrets**: `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` from secure storage

<!-- AI-CONTEXT-END -->

## Security

- **Rate limiting**: configure `rate_limiting.default_limit` in deployment config
- **Hook security**: never trust user-provided hook code; validate, sandbox, and timeout all hooks
- **Security headers**: set `x_content_type_options`, `x_frame_options`, `content_security_policy`

## MCP Config

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

## API Reference

| Feature | API |
|---------|-----|
| LLM extraction | `LLMExtractionStrategy(llm_config=LLMConfig(provider="openai/gpt-4o"), instruction="...")` |
| Adaptive crawl | `AdaptiveCrawler(crawler, AdaptiveConfig(confidence_threshold=0.7, max_depth=5, max_pages=20))` |
| Browser config | `BrowserConfig(headless=True, viewport={...}, extra_args=[...])` |
| Crawler config | `CrawlerRunConfig(cache_mode=CacheMode.ENABLED, max_depth=3, delay_between_requests=1.0, respect_robots_txt=True)` |
| Virtual scroll | `VirtualScrollConfig(container_selector, scroll_count, scroll_by)` |
| Persistent sessions | `BrowserConfig(use_persistent_context=True, user_data_dir="/path")` |
| Proxy | `BrowserConfig(proxy={"server": "...", "username": "...", "password": "..."})` |
| Browser hooks | `crawler.arun(hooks={"on_page_context_created": setup_hook})` |
| Async job queue | `POST http://localhost:11235/crawl/job` with `webhook_config` |

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Browser not starting | Check Docker `--shm-size=1g` |
| API not responding | Verify container running, port accessible |
| Extraction failing | Validate CSS selectors or LLM config |
| Memory issues | Adjust browser pool size and cleanup intervals |
