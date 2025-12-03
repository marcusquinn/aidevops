# Crawl4AI Resources & Links

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Docs**: https://docs.crawl4ai.com/
- **GitHub**: https://github.com/unclecode/crawl4ai
- **Docker**: `unclecode/crawl4ai:latest`
- **PyPI**: https://pypi.org/project/crawl4ai/
- **MCP NPM**: `npx crawl4ai-mcp-server@latest`
- **Discord**: https://discord.gg/jP8KfhDhyN
- **CapSolver**: https://www.capsolver.com/ (CAPTCHA integration)
- **API Endpoints**: `/crawl`, `/crawl/job`, `/health`, `/metrics`, `/screenshot`, `/pdf`
- **Framework Files**: `.agent/scripts/crawl4ai-helper.sh`, `configs/crawl4ai-config.json.txt`
- **Current Version**: v0.7.7 (November 2024)
<!-- AI-CONTEXT-END -->

## Official Resources

### Primary Documentation

- **Official Documentation**: https://docs.crawl4ai.com/
- **GitHub Repository**: https://github.com/unclecode/crawl4ai
- **Docker Hub**: https://hub.docker.com/r/unclecode/crawl4ai
- **PyPI Package**: https://pypi.org/project/crawl4ai/

### Community & Support

- **Discord Community**: https://discord.gg/jP8KfhDhyN
- **GitHub Issues**: https://github.com/unclecode/crawl4ai/issues
- **GitHub Discussions**: https://github.com/unclecode/crawl4ai/discussions
- **Changelog**: https://github.com/unclecode/crawl4ai/blob/main/CHANGELOG.md

### CapSolver Integration

- **CapSolver Homepage**: https://www.capsolver.com/
- **CapSolver Dashboard**: https://dashboard.capsolver.com/dashboard/overview
- **CapSolver Documentation**: https://docs.capsolver.com/
- **Crawl4AI Partnership**: https://www.capsolver.com/blog/Partners/crawl4ai-capsolver/
- **Chrome Extension**: https://chrome.google.com/webstore/detail/capsolver/pgojnojmmhpofjgdmaebadhbocahppod

## Documentation Sections

### Core Documentation

- **Quick Start**: https://docs.crawl4ai.com/quick-start/
- **Installation**: https://docs.crawl4ai.com/setup-installation/installation/
- **Docker Deployment**: https://docs.crawl4ai.com/setup-installation/docker-deployment/
- **API Reference**: https://docs.crawl4ai.com/api-reference/

### Advanced Features

- **Adaptive Crawling**: https://docs.crawl4ai.com/advanced/adaptive-strategies/
- **Virtual Scroll**: https://docs.crawl4ai.com/advanced/virtual-scroll/
- **Hooks & Authentication**: https://docs.crawl4ai.com/advanced/hooks-auth/
- **Session Management**: https://docs.crawl4ai.com/advanced/session-management/

### Extraction Strategies

- **LLM-Free Strategies**: https://docs.crawl4ai.com/extraction/llm-free-strategies/
- **LLM Strategies**: https://docs.crawl4ai.com/extraction/llm-strategies/
- **Clustering Strategies**: https://docs.crawl4ai.com/extraction/clustering-strategies/
- **Chunking**: https://docs.crawl4ai.com/extraction/chunking/

## Framework Integration

### Helper Scripts

- **Main Helper**: `.agent/scripts/crawl4ai-helper.sh`
- **Examples Script**: `.agent/scripts/crawl4ai-examples.sh`
- **Configuration Template**: `configs/crawl4ai-config.json.txt`
- **MCP Configuration**: `configs/mcp-templates/crawl4ai-mcp-config.json`

### Documentation Files

- **Main Guide**: `.agent/crawl4ai.md`
- **Integration Guide**: `.agent/wiki/crawl4ai-integration.md`
- **Usage Guide**: `.agent/spec/crawl4ai-usage.md`
- **Resources**: `.agent/links/crawl4ai-resources.md` (this file)

## MCP Integration

### MCP Server

- **NPM Package**: https://www.npmjs.com/package/crawl4ai-mcp-server
- **Installation**: `npx crawl4ai-mcp-server@latest`
- **Documentation**: https://docs.crawl4ai.com/core/docker-deployment/#mcp-model-context-protocol-support

### Claude Desktop Integration

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

## Docker Resources

### Docker Images

- **Latest Release**: `unclecode/crawl4ai:latest`
- **Specific Version**: `unclecode/crawl4ai:0.7.7`
- **Multi-Architecture**: Supports AMD64 and ARM64

### Docker Compose

- **Example Compose**: https://github.com/unclecode/crawl4ai/blob/main/docker-compose.yml
- **Environment Variables**: https://docs.crawl4ai.com/core/docker-deployment/#environment-setup-api-keys

## Use Case Examples

### Content Research

- **News Aggregation**: Extract articles from multiple news sources
- **Academic Papers**: Extract titles, authors, abstracts, and citations
- **Documentation**: Process API docs and technical documentation

### E-commerce Data

- **Product Information**: Extract names, prices, descriptions, specifications
- **Inventory Tracking**: Monitor stock levels and price changes
- **Competitor Analysis**: Compare products across different sites

### SEO & Marketing

- **Content Analysis**: Extract headings, meta tags, and content structure
- **Link Analysis**: Discover internal and external link patterns
- **Performance Monitoring**: Track page changes and updates

## API Endpoints

### Core Endpoints

- **Crawl**: `POST /crawl` - Synchronous crawling
- **Crawl Job**: `POST /crawl/job` - Asynchronous crawling with webhooks
- **LLM Job**: `POST /llm/job` - LLM extraction with webhooks
- **Job Status**: `GET /job/{task_id}` - Check job status

### Utility Endpoints

- **Health**: `GET /health` - Service health check
- **Metrics**: `GET /metrics` - Prometheus metrics
- **Schema**: `GET /schema` - API schema documentation
- **Dashboard**: `GET /dashboard` - Monitoring dashboard
- **Playground**: `GET /playground` - Interactive testing interface

### Media Endpoints

- **Screenshot**: `POST /screenshot` - Capture page screenshots
- **PDF**: `POST /pdf` - Generate PDF from webpage
- **HTML**: `POST /html` - Extract raw HTML
- **JavaScript**: `POST /js` - Execute JavaScript on page

## Security Resources

### Best Practices

- **Rate Limiting**: Built-in protection against abuse
- **User Agent**: Clear identification as Crawl4AI
- **Robots.txt**: Respects robots.txt by default
- **Timeout Protection**: Prevents hanging requests

### Authentication

- **JWT Support**: Optional JWT authentication for API access
- **API Keys**: Secure API key management for LLM providers
- **Webhook Security**: Custom headers for webhook authentication

## Monitoring & Analytics

### Dashboard Features

- **System Metrics**: CPU, memory, network utilization
- **Request Analytics**: Success rates, response times, error tracking
- **Browser Pool**: Active/hot/cold browser instances management
- **Job Queue**: Real-time job processing status

### Metrics Integration

- **Prometheus**: Native Prometheus metrics export
- **Health Checks**: Comprehensive health monitoring
- **Performance Tracking**: Request timing and resource usage

## Performance Optimization

### Configuration Tips

- **Browser Pool Size**: Optimize based on available resources
- **Concurrent Requests**: Balance speed vs resource usage
- **Memory Management**: Configure cleanup intervals and thresholds
- **Caching**: Use appropriate cache modes for your use case

### Resource Management

- **Docker Memory**: Allocate sufficient shared memory (--shm-size=1g)
- **CPU Throttling**: Configure CPU limits for container
- **Network Optimization**: Use appropriate timeouts and retry policies

## Version Information

### Current Version

- **Latest Stable**: v0.7.7
- **Release Date**: November 2024
- **Breaking Changes**: Check CHANGELOG.md for migration notes

### Version History

- **v0.7.7**: Self-hosting platform with real-time monitoring
- **v0.7.6**: Complete webhook infrastructure for job queue API
- **v0.7.5**: Docker hooks system with function-based API
- **v0.7.4**: Intelligent table extraction & performance updates

## Learning Resources

### Tutorials & Guides

- **Video Tutorial**: Available on documentation homepage
- **Code Examples**: https://github.com/unclecode/crawl4ai/tree/main/.agent/examples
- **Blog Posts**: Check GitHub discussions for community tutorials

### Community Examples

- **GitHub Examples**: Real-world usage examples in repository
- **Discord Discussions**: Community-shared patterns and solutions
- **Stack Overflow**: Tagged questions and answers

## Contributing

### Development

- **Contributing Guide**: https://github.com/unclecode/crawl4ai/blob/main/CONTRIBUTING.md
- **Code of Conduct**: https://github.com/unclecode/crawl4ai/blob/main/CODE_OF_CONDUCT.md
- **Development Setup**: Local development instructions in README

### Sponsorship

- **GitHub Sponsors**: Support the project development
- **Enterprise Support**: Commercial support options available
- **Community Recognition**: Contributors acknowledged in project

## Support Channels

### Technical Support

1. **GitHub Issues**: Bug reports and feature requests
2. **Discord Community**: Real-time community support
3. **Documentation**: Comprehensive guides and API reference
4. **Stack Overflow**: Tag questions with `crawl4ai`

### Enterprise Support

- **Commercial Licensing**: Available for enterprise use
- **Priority Support**: Dedicated support channels
- **Custom Development**: Tailored solutions and integrations

This resource collection provides comprehensive access to all Crawl4AI documentation, tools, and community resources for effective integration within the AI DevOps Framework.
