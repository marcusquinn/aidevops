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
- **Install**: `./.agent/scripts/crawl4ai-helper.sh install`
- **Docker**: `./.agent/scripts/crawl4ai-helper.sh docker-start`
- **MCP Setup**: `./.agent/scripts/crawl4ai-helper.sh mcp-setup`

**Endpoints** (Docker):
- API: http://localhost:11235
- Dashboard: http://localhost:11235/dashboard
- Playground: http://localhost:11235/playground

**Commands**: `install|docker-setup|docker-start|mcp-setup|capsolver-setup|status|crawl|extract|captcha-crawl`

**Key Features**:
- LLM-ready markdown output
- CSS/XPath/LLM extraction strategies
- CAPTCHA solving via CapSolver
- Parallel async crawling
- Session management & browser pool
- Full proxy support (HTTP, SOCKS5, residential)
- Persistent context with `user_data_dir`

**Performance**: Structured extraction 2.5s (30 items), multi-page 3.8s (3 URLs), reliability 0.52s avg (fastest).
Purpose-built for extraction - cannot fill forms or click buttons.

**Parallel**: `arun_many(urls)` for built-in parallel crawling (tested: 1.7x speedup over sequential). Multiple `AsyncWebCrawler` instances for fully isolated browsers.

**AI Page Understanding**: Returns LLM-ready markdown by default. Use `JsonCssExtractionStrategy` for structured data or `LLMExtractionStrategy` for AI-parsed content. No need for screenshots or ARIA - output is already AI-optimized.

**Limitations**: No extensions, no form filling, no interactive automation. No Chrome DevTools MCP pairing.

**Install**: `python3 -m venv ~/.aidevops/crawl4ai-venv && source ~/.aidevops/crawl4ai-venv/bin/activate && pip install crawl4ai && crawl4ai-setup`

**Env Vars**: `OPENAI_API_KEY`, `CAPSOLVER_API_KEY`, `CRAWL4AI_MAX_PAGES=50`
<!-- AI-CONTEXT-END -->

## 🚀 Overview

Crawl4AI is the #1 trending open-source web crawler on GitHub, specifically designed for AI and LLM applications. This integration provides comprehensive web crawling and data extraction capabilities for the AI DevOps Framework.

### Key Features

- **🤖 LLM-Ready Output**: Clean markdown generation perfect for RAG pipelines
- **📊 Structured Extraction**: CSS selectors, XPath, and LLM-based data extraction  
- **🎛️ Advanced Browser Control**: Hooks, proxies, stealth modes, session management
- **⚡ High Performance**: Parallel crawling, async operations, real-time processing
- **🔌 AI Integration**: Native MCP support for AI assistants like Claude
- **📈 Enterprise Features**: Monitoring dashboard, job queues, webhook notifications
- **🤖 CAPTCHA Solving**: Integrated CapSolver support for automated CAPTCHA bypass
- **🛡️ Anti-Bot Measures**: Handle Cloudflare, AWS WAF, and other protection systems

## 🛠️ Quick Start

### Installation

```bash
# Install Crawl4AI Python package
./.agent/scripts/crawl4ai-helper.sh install

# Setup Docker deployment with monitoring
./.agent/scripts/crawl4ai-helper.sh docker-setup

# Start Docker container
./.agent/scripts/crawl4ai-helper.sh docker-start

# Setup MCP integration for AI assistants
./.agent/scripts/crawl4ai-helper.sh mcp-setup

# Setup CapSolver for CAPTCHA solving
./.agent/scripts/crawl4ai-helper.sh capsolver-setup

# Check status
./.agent/scripts/crawl4ai-helper.sh status
```

### Basic Usage

```bash
# Crawl a single URL
./.agent/scripts/crawl4ai-helper.sh crawl https://example.com markdown output.json

# Extract structured data
./.agent/scripts/crawl4ai-helper.sh extract https://example.com '{"title":"h1","content":".article"}' data.json

# Crawl with CAPTCHA solving (requires CapSolver API key)
export CAPSOLVER_API_KEY="CAP-xxxxxxxxxxxxxxxxxxxxx"
./.agent/scripts/crawl4ai-helper.sh captcha-crawl https://example.com recaptcha_v2 6LfW6wATAAAAAHLqO2pb8bDBahxlMxNdo9g947u9
```

## 🐳 Docker Deployment

The Docker deployment includes a comprehensive suite of features:

### Services Available

- **API Server**: http://localhost:11235
- **Monitoring Dashboard**: http://localhost:11235/dashboard  
- **Interactive Playground**: http://localhost:11235/playground
- **Health Check**: http://localhost:11235/health
- **Metrics**: http://localhost:11235/metrics

### Key Features

- **Real-time Monitoring**: System health, memory usage, request tracking
- **Browser Pool Management**: Efficient browser instance management
- **Job Queue System**: Asynchronous processing with webhook notifications
- **WebSocket Streaming**: Real-time crawl results
- **Multi-architecture Support**: AMD64 and ARM64 compatibility

## 🔌 MCP Integration

Crawl4AI provides native Model Context Protocol (MCP) support for AI assistants:

### Claude Desktop Setup

Add to your Claude Desktop configuration:

```json
{
  "mcpServers": {
    "crawl4ai": {
      "command": "npx",
      "args": ["crawl4ai-mcp-server@latest"],
      "env": {
        "CRAWL4AI_API_URL": "http://localhost:11235"
      }
    }
  }
}
```

### Available MCP Tools

- **crawl_url**: Crawl single URL with format options
- **crawl_multiple**: Batch crawl multiple URLs  
- **extract_structured**: Extract data using CSS selectors or LLM
- **take_screenshot**: Capture webpage screenshots
- **generate_pdf**: Convert webpages to PDF
- **execute_javascript**: Run custom JavaScript on pages
- **solve_captcha**: Solve CAPTCHA challenges using CapSolver
- **crawl_with_captcha**: Crawl URLs with automatic CAPTCHA solving
- **check_captcha_balance**: Monitor CapSolver account balance

## 🤖 CapSolver Integration for CAPTCHA Solving

Crawl4AI integrates with CapSolver, the world's leading automated CAPTCHA solving service, to handle anti-bot measures seamlessly.

### Supported CAPTCHA Types

- **reCAPTCHA v2/v3**: Including Enterprise versions with high success rates
- **Cloudflare Turnstile**: Modern CAPTCHA alternative bypass
- **Cloudflare Challenge**: 5-second shield and anti-bot protection
- **AWS WAF**: Web Application Firewall bypass
- **GeeTest v3/v4**: Popular CAPTCHA system in Asia
- **Image-to-Text**: Traditional OCR-based CAPTCHAs

### Quick Setup

```bash
# Setup CapSolver integration
./.agent/scripts/crawl4ai-helper.sh capsolver-setup

# Get API key from https://dashboard.capsolver.com/
export CAPSOLVER_API_KEY="CAP-xxxxxxxxxxxxxxxxxxxxx"

# Crawl with CAPTCHA solving
./.agent/scripts/crawl4ai-helper.sh captcha-crawl https://example.com recaptcha_v2 site_key_here
```

### Pricing & Performance

- **Cost**: Starting from $0.4/1000 requests
- **Speed**: Most CAPTCHAs solved in < 10 seconds
- **Success Rate**: 99.9% accuracy
- **Package Discounts**: Up to 60% savings available

### Integration Methods

1. **API Integration** (Recommended): Direct Python SDK integration
2. **Browser Extension**: Automatic detection and solving

## 📊 Core Capabilities

### 1. Web Crawling

```python
import asyncio
from crawl4ai import AsyncWebCrawler

async def basic_crawl():
    async with AsyncWebCrawler() as crawler:
        result = await crawler.arun(url="https://example.com")
        return result.markdown
```

### 2. Structured Data Extraction

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

### 3. LLM-Powered Extraction

```python
from crawl4ai import LLMExtractionStrategy, LLMConfig

llm_strategy = LLMExtractionStrategy(
    llm_config=LLMConfig(provider="openai/gpt-4o"),
    instruction="Extract key information and create a summary"
)

result = await crawler.arun(url="https://article.com", extraction_strategy=llm_strategy)
```

### 4. Advanced Browser Control

```python
# Custom hooks for advanced control
async def setup_hook(page, context, **kwargs):
    # Block images for faster crawling
    await context.route("**/*.{png,jpg,gif}", lambda r: r.abort())
    # Set custom viewport
    await page.set_viewport_size({"width": 1920, "height": 1080})
    return page

result = await crawler.arun(
    url="https://example.com",
    hooks={"on_page_context_created": setup_hook}
)
```

## 🔄 Job Queue & Webhooks

### Asynchronous Processing

```python
import requests

# Submit crawl job
response = requests.post("http://localhost:11235/crawl/job", json={
    "urls": ["https://example.com"],
    "webhook_config": {
        "webhook_url": "https://your-app.com/webhook",
        "webhook_data_in_payload": True,
        "webhook_headers": {
            "X-Webhook-Secret": "your-secret-token"
        }
    }
})

task_id = response.json()["task_id"]
```

### Webhook Handler

```python
from flask import Flask, request, jsonify

app = Flask(__name__)

@app.route('/webhook', methods=['POST'])
def handle_webhook():
    payload = request.json
    
    if payload['status'] == 'completed':
        # Process successful crawl
        data = payload['data']
        markdown = data.get('markdown', '')
        extracted = data.get('extracted_content', {})
        
        # Your processing logic here
        print(f"Crawl completed: {len(markdown)} characters extracted")
        
    elif payload['status'] == 'failed':
        # Handle failure
        error = payload.get('error', 'Unknown error')
        print(f"Crawl failed: {error}")
    
    return jsonify({"status": "received"}), 200
```

## 🎯 Use Cases

### 1. Content Research & Analysis

```bash
# Research articles and papers
./.agent/scripts/crawl4ai-helper.sh extract https://research-paper.com '{
  "title": "h1",
  "authors": ".authors",
  "abstract": ".abstract", 
  "sections": {
    "selector": ".section",
    "fields": [
      {"name": "heading", "selector": "h2", "type": "text"},
      {"name": "content", "selector": "p", "type": "text"}
    ]
  }
}' research.json
```

### 2. E-commerce Data Collection

```bash
# Product information extraction
./.agent/scripts/crawl4ai-helper.sh extract https://ecommerce.com/product '{
  "name": "h1.product-title",
  "price": ".price-current",
  "description": ".product-description",
  "specifications": {
    "selector": ".specs tr",
    "fields": [
      {"name": "feature", "selector": "td:first-child", "type": "text"},
      {"name": "value", "selector": "td:last-child", "type": "text"}
    ]
  },
  "images": {"selector": ".product-images img", "type": "attribute", "attribute": "src"}
}' product.json
```

### 3. News Aggregation

```bash
# Multiple news sources
urls=("https://news1.com" "https://news2.com" "https://news3.com")

for url in "${urls[@]}"; do
    ./.agent/scripts/crawl4ai-helper.sh extract "$url" '{
      "headline": "h1",
      "summary": ".article-summary",
      "author": ".byline",
      "date": ".publish-date",
      "content": ".article-body"
    }' "news-$(basename $url).json"
done
```

### 4. Documentation Processing

```bash
# API documentation extraction
./.agent/scripts/crawl4ai-helper.sh extract https://api-docs.com '{
  "endpoints": {
    "selector": ".endpoint",
    "fields": [
      {"name": "method", "selector": ".method", "type": "text"},
      {"name": "path", "selector": ".path", "type": "text"},
      {"name": "description", "selector": ".description", "type": "text"},
      {"name": "parameters", "selector": ".params", "type": "html"},
      {"name": "examples", "selector": ".examples", "type": "html"}
    ]
  }
}' api-docs.json
```

## 🔧 Configuration

### Environment Variables

```bash
# LLM Configuration
OPENAI_API_KEY=sk-your-key
ANTHROPIC_API_KEY=your-anthropic-key
LLM_PROVIDER=openai/gpt-4o-mini
LLM_TEMPERATURE=0.7

# Crawl4AI Settings
CRAWL4AI_MAX_PAGES=50
CRAWL4AI_TIMEOUT=60
CRAWL4AI_DEFAULT_FORMAT=markdown
CRAWL4AI_CONCURRENT_REQUESTS=5
```

### Docker Configuration

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

## 📊 Monitoring & Analytics

### Dashboard Features

Access the monitoring dashboard at http://localhost:11235/dashboard:

- **System Metrics**: CPU, memory, network utilization
- **Request Analytics**: Success rates, response times, error tracking  
- **Browser Pool**: Active/hot/cold browser instances
- **Job Queue**: Pending, processing, completed jobs
- **Real-time Logs**: Live system and application logs

### API Metrics

```bash
# Prometheus metrics
curl http://localhost:11235/metrics

# Health status
curl http://localhost:11235/health | jq '.'

# API schema
curl http://localhost:11235/schema | jq '.'
```

## 🔒 Security & Best Practices

### Rate Limiting

```yaml
rate_limiting:
  enabled: true
  default_limit: "1000/minute"
  trusted_proxies: []
```

### Security Headers

```yaml
security:
  headers:
    x_content_type_options: "nosniff"
    x_frame_options: "DENY"
    content_security_policy: "default-src 'self'"
    strict_transport_security: "max-age=63072000"
```

### Safe Crawling

- **Respect robots.txt**: Enabled by default
- **Rate limiting**: Built-in delays between requests
- **User agent identification**: Clear identification as Crawl4AI
- **Timeout protection**: Prevents hanging requests
- **Resource blocking**: Block unnecessary resources for performance

## 🛠️ Advanced Features

### Adaptive Crawling

```python
from crawl4ai import AdaptiveCrawler, AdaptiveConfig

config = AdaptiveConfig(
    confidence_threshold=0.7,
    max_depth=5,
    max_pages=20,
    strategy="statistical"
)

adaptive_crawler = AdaptiveCrawler(crawler, config)
state = await adaptive_crawler.digest(
    start_url="https://news.example.com",
    query="latest technology news"
)
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

result = await crawler.arun(
    url="https://infinite-scroll-site.com",
    virtual_scroll_config=scroll_config
)
```

### Session Management

```python
# Persistent browser sessions
browser_config = BrowserConfig(
    use_persistent_context=True,
    user_data_dir="/path/to/profile",
    headless=True
)

async with AsyncWebCrawler(config=browser_config) as crawler:
    # Session persists across requests
    result1 = await crawler.arun("https://site.com/login")
    result2 = await crawler.arun("https://site.com/dashboard")
```

## 🔧 Troubleshooting

### Common Issues

1. **Container won't start**: Check Docker memory allocation

   ```bash
   docker run --shm-size=1g unclecode/crawl4ai:latest
   ```

2. **API not responding**: Verify container status and port mapping

   ```bash
   docker ps | grep crawl4ai
   curl http://localhost:11235/health
   ```

3. **Extraction failing**: Validate CSS selectors or LLM configuration

   ```bash
   # Test in playground
   open http://localhost:11235/playground
   ```

### Debug Commands

```bash
# Check comprehensive status
./.agent/scripts/crawl4ai-helper.sh status

# View container logs
docker logs crawl4ai --tail 50 --follow

# Test basic functionality
curl -X POST http://localhost:11235/crawl \
  -H "Content-Type: application/json" \
  -d '{"urls": ["https://httpbin.org/html"]}'
```

## 📚 Resources

### Framework Integration

- **Helper Script**: `.agent/scripts/crawl4ai-helper.sh`
- **Configuration Template**: `configs/crawl4ai-config.json.txt`
- **MCP Configuration**: `configs/mcp-templates/crawl4ai-mcp-config.json`
- **Integration Guide**: `.agent/wiki/crawl4ai-integration.md`
- **Usage Guide**: `.agent/spec/crawl4ai-usage.md`

### Official Resources

- **Documentation**: https://docs.crawl4ai.com/
- **GitHub Repository**: https://github.com/unclecode/crawl4ai
- **Docker Hub**: https://hub.docker.com/r/unclecode/crawl4ai
- **Discord Community**: https://discord.gg/jP8KfhDhyN

## 🎯 Next Steps

1. **Install and Setup**: Run `./.agent/scripts/crawl4ai-helper.sh install`
2. **Start Docker Services**: Run `./.agent/scripts/crawl4ai-helper.sh docker-start`
3. **Explore Dashboard**: Visit http://localhost:11235/dashboard
4. **Try Playground**: Test crawling at http://localhost:11235/playground
5. **Setup MCP**: Run `./.agent/scripts/crawl4ai-helper.sh mcp-setup`
6. **Build Applications**: Use the API for your specific use cases

Crawl4AI transforms web data into AI-ready formats, making it perfect for RAG systems, data pipelines, and AI-powered applications within the AI DevOps Framework.
