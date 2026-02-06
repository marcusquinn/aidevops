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

# Crawl4AI Usage Guide for AI Assistants

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `.agents/scripts/crawl4ai-helper.sh`
- **API Port**: `localhost:11235`
- **Commands**: `install | docker-setup | docker-start | status | crawl | extract | mcp-setup`
- **Crawl**: `./crawl4ai-helper.sh crawl URL markdown output.json`
- **Extract**: `./crawl4ai-helper.sh extract URL '{"title":"h1"}' data.json`
- **MCP Tools**: `crawl_url | crawl_multiple | extract_structured | take_screenshot | generate_pdf`
- **Dashboard**: `http://localhost:11235/dashboard`
- **Playground**: `http://localhost:11235/playground`
- **Output**: JSON with markdown, html, extracted_content, links, media, metadata
- **Process results**: `jq -r '.results[0].markdown' output.json`
<!-- AI-CONTEXT-END -->

## Purpose

This guide provides AI assistants with comprehensive instructions for using Crawl4AI within the AI DevOps Framework for web crawling, data extraction, and content processing tasks.

## Quick Start Commands

### Basic Setup

```bash
# Install Crawl4AI
./.agents/scripts/crawl4ai-helper.sh install

# Setup Docker deployment
./.agents/scripts/crawl4ai-helper.sh docker-setup

# Start services
./.agents/scripts/crawl4ai-helper.sh docker-start

# Check status
./.agents/scripts/crawl4ai-helper.sh status
```

### MCP Integration

```bash
# Setup MCP server for AI assistants
./.agents/scripts/crawl4ai-helper.sh mcp-setup
```

## Core Operations

### 1. Web Crawling

```bash
# Basic crawling - extract markdown
./.agents/scripts/crawl4ai-helper.sh crawl https://example.com markdown output.json

# Crawl with specific format
./.agents/scripts/crawl4ai-helper.sh crawl https://news.com html news.json

# Save to file
./.agents/scripts/crawl4ai-helper.sh crawl https://docs.com markdown ~/Downloads/docs.json
```

### 2. Structured Data Extraction

```bash
# Extract with CSS selectors
./.agents/scripts/crawl4ai-helper.sh extract https://example.com '{"title":"h1","content":".article"}' data.json

# Complex schema extraction
./.agents/scripts/crawl4ai-helper.sh extract https://ecommerce.com '{
  "products": {
    "selector": ".product",
    "fields": [
      {"name": "title", "selector": "h2", "type": "text"},
      {"name": "price", "selector": ".price", "type": "text"},
      {"name": "image", "selector": "img", "type": "attribute", "attribute": "src"}
    ]
  }
}' products.json
```

## AI Assistant Integration Patterns

### For Claude Desktop

1. **Setup MCP Configuration**:

   ```json
   {
     "mcpServers": {
       "crawl4ai": {
         "command": "npx",
         "args": ["crawl4ai-mcp-server@latest"]
       }
     }
   }
   ```

2. **Available Tools**:
   - `crawl_url`: Single URL crawling
   - `crawl_multiple`: Batch URL processing
   - `extract_structured`: Data extraction
   - `take_screenshot`: Page screenshots
   - `generate_pdf`: PDF conversion

### For Other AI Assistants

Use the REST API directly:

```python
import requests

# Basic crawl
response = requests.post("http://localhost:11235/crawl", json={
    "urls": ["https://example.com"],
    "crawler_config": {
        "type": "CrawlerRunConfig",
        "params": {"cache_mode": "bypass"}
    }
})

# Extract structured data
response = requests.post("http://localhost:11235/crawl", json={
    "urls": ["https://example.com"],
    "crawler_config": {
        "type": "CrawlerRunConfig",
        "params": {
            "extraction_strategy": {
                "type": "JsonCssExtractionStrategy",
                "params": {
                    "schema": {
                        "type": "dict",
                        "value": {"title": "h1", "content": ".article"}
                    }
                }
            }
        }
    }
})
```

## Common Use Cases

### 1. Content Research

```bash
# Research articles
./.agents/scripts/crawl4ai-helper.sh crawl https://research-site.com markdown research.json

# Extract key information
./.agents/scripts/crawl4ai-helper.sh extract https://paper.com '{
  "title": "h1",
  "authors": ".authors",
  "abstract": ".abstract",
  "keywords": ".keywords"
}' paper-data.json
```

### 2. News Aggregation

```bash
# Multiple news sources
for url in "https://news1.com" "https://news2.com" "https://news3.com"; do
    ./.agents/scripts/crawl4ai-helper.sh crawl "$url" markdown "news-$(basename $url).json"
done
```

### 3. E-commerce Data

```bash
# Product information
./.agents/scripts/crawl4ai-helper.sh extract https://shop.com/product '{
  "name": "h1.product-title",
  "price": ".price-current",
  "description": ".product-description",
  "specs": {
    "selector": ".specs tr",
    "fields": [
      {"name": "feature", "selector": "td:first-child", "type": "text"},
      {"name": "value", "selector": "td:last-child", "type": "text"}
    ]
  }
}' product.json
```

### 4. Documentation Processing

```bash
# API documentation
./.agents/scripts/crawl4ai-helper.sh extract https://api-docs.com '{
  "endpoints": {
    "selector": ".endpoint",
    "fields": [
      {"name": "method", "selector": ".method", "type": "text"},
      {"name": "path", "selector": ".path", "type": "text"},
      {"name": "description", "selector": ".description", "type": "text"},
      {"name": "parameters", "selector": ".params", "type": "html"}
    ]
  }
}' api-docs.json
```

## Advanced Workflows

### Batch Processing

```bash
#!/bin/bash
# Process multiple URLs with different strategies

urls=(
    "https://news.com"
    "https://blog.com" 
    "https://docs.com"
)

for url in "${urls[@]}"; do
    echo "Processing: $url"
    ./.agents/scripts/crawl4ai-helper.sh crawl "$url" markdown "output-$(date +%s).json"
    sleep 2  # Rate limiting
done
```

### Content Analysis Pipeline

```bash
#!/bin/bash
# Complete content analysis workflow

URL="https://example.com"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 1. Basic crawl
./.agents/scripts/crawl4ai-helper.sh crawl "$URL" markdown "raw-$TIMESTAMP.json"

# 2. Extract structured data
./.agents/scripts/crawl4ai-helper.sh extract "$URL" '{
  "title": "h1",
  "headings": "h2, h3",
  "links": {"selector": "a", "type": "attribute", "attribute": "href"},
  "images": {"selector": "img", "type": "attribute", "attribute": "src"}
}' "structured-$TIMESTAMP.json"

echo "Analysis complete: raw-$TIMESTAMP.json and structured-$TIMESTAMP.json"
```

## Configuration Best Practices

### Environment Setup

```bash
# Create dedicated environment file
cat > ~/.aidevops/.agent-workspace/tmp/crawl4ai.env << EOF
OPENAI_API_KEY=your-key-here
LLM_PROVIDER=openai/gpt-4o-mini
LLM_TEMPERATURE=0.7
CRAWL4AI_MAX_PAGES=50
CRAWL4AI_TIMEOUT=60
EOF
```

### Performance Optimization

```bash
# For high-volume crawling
export CRAWL4AI_CONCURRENT_REQUESTS=5
export CRAWL4AI_BROWSER_POOL_SIZE=3
export CRAWL4AI_MEMORY_THRESHOLD=90
```

## Monitoring & Debugging

### Status Checks

```bash
# Comprehensive status
./.agents/scripts/crawl4ai-helper.sh status

# Docker container status
docker ps | grep crawl4ai

# API health
curl -s http://localhost:11235/health | jq '.'

# Metrics
curl -s http://localhost:11235/metrics
```

### Dashboard Access

- **Monitoring Dashboard**: http://localhost:11235/dashboard
- **Interactive Playground**: http://localhost:11235/playground
- **API Documentation**: http://localhost:11235/schema

### Troubleshooting

```bash
# Container logs
docker logs crawl4ai --tail 50

# Restart services
./.agents/scripts/crawl4ai-helper.sh docker-stop
./.agents/scripts/crawl4ai-helper.sh docker-start

# Test basic functionality
curl -X POST http://localhost:11235/crawl \
  -H "Content-Type: application/json" \
  -d '{"urls": ["https://httpbin.org/html"]}'
```

## Output Processing

### JSON Response Structure

```json
{
  "success": true,
  "results": [
    {
      "url": "https://example.com",
      "success": true,
      "markdown": "# Page Title\n\nContent...",
      "html": "<html>...</html>",
      "extracted_content": {...},
      "links": {...},
      "media": {...},
      "metadata": {...}
    }
  ]
}
```

### Processing Results

```bash
# Extract just the markdown
jq -r '.results[0].markdown' output.json > content.md

# Get extracted data
jq '.results[0].extracted_content' output.json > data.json

# List all links
jq -r '.results[0].links.internal[]' output.json
```

## Security Considerations

### Safe Crawling Practices

1. **Respect robots.txt**: Always enabled by default
2. **Rate limiting**: Built-in delays between requests
3. **User agent**: Identifies as Crawl4AI
4. **Timeout protection**: Prevents hanging requests

### Data Privacy

```bash
# Use cache mode for repeated requests
./.agents/scripts/crawl4ai-helper.sh crawl https://example.com markdown output.json

# Clear cache when needed
docker exec crawl4ai redis-cli FLUSHALL
```

## Integration Tips

### With Other Framework Tools

```bash
# Combine with quality tools
./.agents/scripts/crawl4ai-helper.sh crawl https://docs.com markdown docs.json
cat docs.json | jq -r '.results[0].markdown' | ./.agents/scripts/pandoc-helper.sh convert - pdf docs.pdf
```

### With AI Workflows

```bash
# Extract content for AI processing
./.agents/scripts/crawl4ai-helper.sh crawl https://article.com markdown article.json
CONTENT=$(jq -r '.results[0].markdown' article.json)
echo "$CONTENT" | # Process with your AI pipeline
```

## Resources

- **Helper Script**: `.agents/scripts/crawl4ai-helper.sh`
- **Configuration**: `configs/crawl4ai-config.json.txt`
- **MCP Setup**: `configs/mcp-templates/crawl4ai-mcp-config.json`
- **Integration Guide**: `.agents/wiki/crawl4ai-integration.md`
- **Official Docs**: https://docs.crawl4ai.com/

## Success Checklist

- [ ] Crawl4AI installed and running
- [ ] Docker container started successfully
- [ ] MCP integration configured
- [ ] Basic crawling test completed
- [ ] Structured extraction working
- [ ] Dashboard accessible
- [ ] API endpoints responding

Use this guide to effectively leverage Crawl4AI's powerful web crawling and data extraction capabilities within your AI workflows.
