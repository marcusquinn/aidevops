---
description: Crawl4AI usage patterns and best practices
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

# Crawl4AI Usage Guide for AI Assistants

## Quick Reference

- **Helper**: `.agents/scripts/crawl4ai-helper.sh`
- **API Port**: `localhost:11235`
- **Commands**: `install | docker-setup | docker-start | status | crawl | extract | mcp-setup`
- **Crawl**: `./crawl4ai-helper.sh crawl URL markdown output.json`
- **Extract**: `./crawl4ai-helper.sh extract URL '{"title":"h1"}' data.json`
- **MCP Tools**: `crawl_url | crawl_multiple | extract_structured | take_screenshot | generate_pdf`
- **Output**: JSON with `markdown`, `html`, `extracted_content`, `links`, `media`, `metadata`
- **Config template**: `configs/crawl4ai-config.json.txt`
- **MCP template**: `configs/mcp-templates/crawl4ai-mcp-config.json`
- **Integration guide**: `.agents/tools/browser/crawl4ai-integration.md`
- **Official docs**: https://docs.crawl4ai.com/

## Setup

```bash
./.agents/scripts/crawl4ai-helper.sh install
./.agents/scripts/crawl4ai-helper.sh docker-setup && docker-start
./.agents/scripts/crawl4ai-helper.sh mcp-setup   # MCP server for AI assistants
```

## Core Operations

```bash
# Crawl (markdown or html)
./.agents/scripts/crawl4ai-helper.sh crawl https://example.com markdown output.json

# Extract with CSS selectors
./.agents/scripts/crawl4ai-helper.sh extract https://example.com '{"title":"h1","content":".article"}' data.json

# Extract nested schema
./.agents/scripts/crawl4ai-helper.sh extract https://shop.com '{
  "products": {
    "selector": ".product",
    "fields": [
      {"name": "title", "selector": "h2", "type": "text"},
      {"name": "price", "selector": ".price", "type": "text"},
      {"name": "image", "selector": "img", "type": "attribute", "attribute": "src"}
    ]
  }
}' products.json

# Batch with rate limiting
for url in "${urls[@]}"; do
    ./.agents/scripts/crawl4ai-helper.sh crawl "$url" markdown "output-$(date +%s).json"
    sleep 2
done

# Crawl → PDF via pandoc (write to temp file; pandoc-helper.sh requires a real file path)
./.agents/scripts/crawl4ai-helper.sh crawl https://docs.com markdown docs.json
jq -r '.results[0].markdown' docs.json > /tmp/docs-crawl.md
./.agents/scripts/pandoc-helper.sh convert /tmp/docs-crawl.md pdf docs.pdf
```

## AI Assistant Integration

**MCP (Claude Desktop)** — add to MCP config:

```json
{"mcpServers": {"crawl4ai": {"command": "npx", "args": ["crawl4ai-mcp-server@latest"]}}}
```

**REST API (other assistants)**:

```bash
curl -s -X POST http://localhost:11235/crawl \
  -H "Content-Type: application/json" \
  -d '{"urls":["https://example.com"],"crawler_config":{"type":"CrawlerRunConfig","params":{"cache_mode":"bypass"}}}' \
  | jq -r '.results[0].markdown'
```

## Output Processing

```bash
jq -r '.results[0].markdown' output.json > content.md
jq '.results[0].extracted_content' output.json > data.json
jq -r '.results[0].links.internal[]' output.json
```

## Configuration

```bash
# Performance (high-volume)
export CRAWL4AI_CONCURRENT_REQUESTS=5
export CRAWL4AI_BROWSER_POOL_SIZE=3
export CRAWL4AI_MEMORY_THRESHOLD=90

# LLM extraction — store secrets via `aidevops secret set`, never plaintext
export LLM_PROVIDER=openai/gpt-4o-mini
export CRAWL4AI_MAX_PAGES=50
export CRAWL4AI_TIMEOUT=60
```

## Security

- robots.txt respected by default; built-in rate limiting and timeout protection
- User agent identifies as Crawl4AI
- Clear cache: `docker exec crawl4ai redis-cli FLUSHALL`
- **Never write API keys to files** — use `aidevops secret set OPENAI_API_KEY`

## Monitoring & Debugging

```bash
./.agents/scripts/crawl4ai-helper.sh status
curl -s http://localhost:11235/health | jq '.'
docker logs crawl4ai --tail 50
./.agents/scripts/crawl4ai-helper.sh docker-stop && ./.agents/scripts/crawl4ai-helper.sh docker-start

# Smoke test
curl -X POST http://localhost:11235/crawl \
  -H "Content-Type: application/json" \
  -d '{"urls": ["https://httpbin.org/html"]}'
```

Endpoints: `/dashboard` | `/playground` | `/schema` | `/metrics`
