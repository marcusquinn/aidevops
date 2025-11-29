# Crawl4AI Integration Guide

## 🚀 Overview

Crawl4AI is the #1 trending open-source web crawler on GitHub, specifically designed for AI and LLM applications. This integration provides comprehensive web crawling and data extraction capabilities for the AI DevOps Framework.

### Key Features

- **LLM-Ready Output**: Clean markdown generation perfect for RAG pipelines
- **Structured Extraction**: CSS selectors, XPath, and LLM-based data extraction
- **Advanced Browser Control**: Hooks, proxies, stealth modes, session management
- **High Performance**: Parallel crawling, async operations, real-time processing
- **AI Integration**: Native MCP support for AI assistants like Claude
- **Enterprise Features**: Monitoring dashboard, job queues, webhook notifications

## 🛠️ Installation & Setup

### Quick Start

```bash
# Install Python package
./.agent/scripts/crawl4ai-helper.sh install

# Setup Docker deployment
./.agent/scripts/crawl4ai-helper.sh docker-setup

# Start Docker container with monitoring dashboard
./.agent/scripts/crawl4ai-helper.sh docker-start

# Setup MCP integration for AI assistants
./.agent/scripts/crawl4ai-helper.sh mcp-setup
```

### Docker Deployment

The Docker deployment includes:

- **Real-time Monitoring Dashboard**: http://localhost:11235/dashboard
- **Interactive Playground**: http://localhost:11235/playground
- **REST API**: http://localhost:11235
- **WebSocket Streaming**: Real-time crawl results
- **Job Queue System**: Asynchronous processing with webhooks

### MCP Integration

Crawl4AI provides native MCP (Model Context Protocol) support for AI assistants:

```json
{
  "crawl4ai": {
    "command": "npx",
    "args": ["crawl4ai-mcp-server@latest"],
    "env": {
      "CRAWL4AI_API_URL": "http://localhost:11235"
    }
  }
}
```

## 🎯 Core Capabilities

### 1. Web Crawling

```bash
# Basic crawling
./.agent/scripts/crawl4ai-helper.sh crawl https://example.com markdown output.json

# With structured extraction
./.agent/scripts/crawl4ai-helper.sh extract https://example.com '{"title":"h1","content":".article"}' data.json
```

### 2. LLM-Powered Extraction

```python
import asyncio
from crawl4ai import AsyncWebCrawler, LLMExtractionStrategy, LLMConfig

async def extract_with_llm():
    async with AsyncWebCrawler() as crawler:
        result = await crawler.arun(
            url="https://example.com",
            extraction_strategy=LLMExtractionStrategy(
                llm_config=LLMConfig(provider="openai/gpt-4o"),
                instruction="Extract key information and summarize"
            )
        )
        return result.extracted_content
```

### 3. Advanced Browser Control

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

### 4. Adaptive Crawling

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

## 🔧 Configuration

### Environment Variables

```bash
# LLM Provider Configuration
OPENAI_API_KEY=sk-your-key
ANTHROPIC_API_KEY=your-anthropic-key
LLM_PROVIDER=openai/gpt-4o-mini
LLM_TEMPERATURE=0.7

# Crawl4AI Settings
CRAWL4AI_MAX_PAGES=50
CRAWL4AI_TIMEOUT=60
CRAWL4AI_DEFAULT_FORMAT=markdown
```

### Browser Configuration

```python
browser_config = BrowserConfig(
    headless=True,
    viewport={"width": 1920, "height": 1080},
    user_agent="Mozilla/5.0 (compatible; Crawl4AI/0.7.7)",
    timeout=30000,
    extra_args=["--disable-blink-features=AutomationControlled"]
)
```

### Crawler Configuration

```python
crawler_config = CrawlerRunConfig(
    cache_mode=CacheMode.ENABLED,
    max_depth=3,
    delay_between_requests=1.0,
    respect_robots_txt=True,
    follow_redirects=True,
    extraction_strategy=JsonCssExtractionStrategy(schema=your_schema)
)
```

## 📊 Monitoring & Analytics

### Dashboard Features

- **Real-time Metrics**: System health, memory usage, request tracking
- **Browser Pool Management**: Active/hot/cold browser instances
- **Request Analytics**: Success rates, response times, error tracking
- **Resource Monitoring**: CPU, memory, network utilization

### API Endpoints

```bash
# Health check
curl http://localhost:11235/health

# Prometheus metrics
curl http://localhost:11235/metrics

# API schema
curl http://localhost:11235/schema
```

## 🔄 Job Queue & Webhooks

### Asynchronous Processing

```python
# Submit crawl job
response = requests.post("http://localhost:11235/crawl/job", json={
    "urls": ["https://example.com"],
    "webhook_config": {
        "webhook_url": "https://your-app.com/webhook",
        "webhook_data_in_payload": True
    }
})

task_id = response.json()["task_id"]
```

### Webhook Notifications

```python
@app.route('/webhook', methods=['POST'])
def handle_webhook():
    payload = request.json
    if payload['status'] == 'completed':
        process_results(payload['data'])
    return "OK", 200
```

## 🤖 AI Assistant Integration

### Claude Desktop Setup

Add to your Claude Desktop MCP configuration:

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

### Available MCP Tools

- `crawl_url`: Crawl single URL with format options
- `crawl_multiple`: Batch crawl multiple URLs
- `extract_structured`: Extract data using CSS or LLM
- `take_screenshot`: Capture webpage screenshots
- `generate_pdf`: Convert webpages to PDF
- `execute_javascript`: Run custom JavaScript on pages

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
```

### Hook Security

- Never trust user-provided hook code
- Validate and sandbox hook execution
- Use timeouts to prevent infinite loops
- Audit hook code before deployment

## 📚 Use Cases

### 1. Content Aggregation

```python
# News aggregation
urls = ["https://news1.com", "https://news2.com", "https://news3.com"]
results = await crawler.arun_many(urls, extraction_strategy=news_schema)
```

### 2. E-commerce Data

```python
# Product information extraction
product_schema = {
    "name": "h1.product-title",
    "price": ".price",
    "description": ".product-description",
    "images": {"selector": "img.product-image", "type": "attribute", "attribute": "src"}
}
```

### 3. Research & Analysis

```python
# Academic paper extraction
paper_extraction = LLMExtractionStrategy(
    instruction="Extract title, authors, abstract, and key findings",
    schema=paper_schema
)
```

### 4. SEO & Marketing

```python
# SEO data extraction
seo_schema = {
    "title": "title",
    "meta_description": "meta[name='description']",
    "headings": "h1, h2, h3",
    "links": {"selector": "a", "type": "attribute", "attribute": "href"}
}
```

## 🚀 Advanced Features

### Virtual Scroll Support

```python
scroll_config = VirtualScrollConfig(
    container_selector="[data-testid='feed']",
    scroll_count=20,
    scroll_by="container_height",
    wait_after_scroll=1.0
)
```

### Session Management

```python
# Persistent browser sessions
browser_config = BrowserConfig(
    use_persistent_context=True,
    user_data_dir="/path/to/profile"
)
```

### Proxy Support

```python
# Proxy configuration
browser_config = BrowserConfig(
    proxy={
        "server": "http://proxy.example.com:8080",
        "username": "user",
        "password": "pass"
    }
)
```

## 🔧 Troubleshooting

### Common Issues

1. **Browser not starting**: Check Docker memory allocation (--shm-size=1g)
2. **API not responding**: Verify container is running and port is accessible
3. **Extraction failing**: Validate CSS selectors or LLM configuration
4. **Memory issues**: Adjust browser pool size and cleanup intervals

### Debug Commands

```bash
# Check service status
./.agent/scripts/crawl4ai-helper.sh status

# View container logs
docker logs crawl4ai

# Test API health
curl http://localhost:11235/health
```

## 📖 Resources

- **Official Documentation**: https://docs.crawl4ai.com/
- **GitHub Repository**: https://github.com/unclecode/crawl4ai
- **Framework Integration**: `.agent/scripts/crawl4ai-helper.sh`
- **Configuration Templates**: `configs/crawl4ai-config.json.txt`
- **MCP Configuration**: `configs/mcp-templates/crawl4ai-mcp-config.json`

## 🎯 Next Steps

1. **Install and Setup**: Run the helper script to get started
2. **Explore Dashboard**: Visit http://localhost:11235/dashboard
3. **Try Playground**: Test crawling at http://localhost:11235/playground
4. **Setup MCP**: Integrate with your AI assistant
5. **Build Applications**: Use the API for your specific use cases

Crawl4AI transforms web data into AI-ready formats, making it perfect for RAG systems, data pipelines, and AI-powered applications.
