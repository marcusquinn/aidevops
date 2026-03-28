---
description: Crawl4AI documentation and resource links
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: true
  task: true
---

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
- **Framework Files**: `.agents/scripts/crawl4ai-helper.sh`, `configs/crawl4ai-config.json.txt`
- **Current Version**: v0.7.7 (November 2024)

<!-- AI-CONTEXT-END -->

## Official Resources

| Resource | URL |
|----------|-----|
| Documentation | https://docs.crawl4ai.com/ |
| GitHub | https://github.com/unclecode/crawl4ai |
| Docker Hub | https://hub.docker.com/r/unclecode/crawl4ai |
| PyPI | https://pypi.org/project/crawl4ai/ |
| Discord | https://discord.gg/jP8KfhDhyN |
| Issues | https://github.com/unclecode/crawl4ai/issues |
| Discussions | https://github.com/unclecode/crawl4ai/discussions |
| Changelog | https://github.com/unclecode/crawl4ai/blob/main/CHANGELOG.md |
| Contributing | https://github.com/unclecode/crawl4ai/blob/main/CONTRIBUTING.md |
| Code of Conduct | https://github.com/unclecode/crawl4ai/blob/main/CODE_OF_CONDUCT.md |
| Code Examples | https://github.com/unclecode/crawl4ai/tree/main/.agents/examples |

### CapSolver Integration

| Resource | URL |
|----------|-----|
| Homepage | https://www.capsolver.com/ |
| Dashboard | https://dashboard.capsolver.com/dashboard/overview |
| Docs | https://docs.capsolver.com/ |
| Partnership | https://www.capsolver.com/blog/Partners/crawl4ai-capsolver/ |
| Chrome Extension | https://chrome.google.com/webstore/detail/capsolver/pgojnojmmhpofjgdmaebadhbocahppod |

## Documentation Sections

### Core

| Topic | URL |
|-------|-----|
| Quick Start | https://docs.crawl4ai.com/quick-start/ |
| Installation | https://docs.crawl4ai.com/setup-installation/installation/ |
| Docker Deployment | https://docs.crawl4ai.com/setup-installation/docker-deployment/ |
| API Reference | https://docs.crawl4ai.com/api-reference/ |

### Advanced Features

| Topic | URL |
|-------|-----|
| Adaptive Crawling | https://docs.crawl4ai.com/advanced/adaptive-strategies/ |
| Virtual Scroll | https://docs.crawl4ai.com/advanced/virtual-scroll/ |
| Hooks & Auth | https://docs.crawl4ai.com/advanced/hooks-auth/ |
| Session Management | https://docs.crawl4ai.com/advanced/session-management/ |

### Extraction Strategies

| Topic | URL |
|-------|-----|
| LLM-Free | https://docs.crawl4ai.com/extraction/llm-free-strategies/ |
| LLM | https://docs.crawl4ai.com/extraction/llm-strategies/ |
| Clustering | https://docs.crawl4ai.com/extraction/clustering-strategies/ |
| Chunking | https://docs.crawl4ai.com/extraction/chunking/ |

## Framework Integration

| File | Purpose |
|------|---------|
| `.agents/scripts/crawl4ai-helper.sh` | Main helper script |
| `.agents/scripts/crawl4ai-examples.sh` | Usage examples |
| `configs/crawl4ai-config.json.txt` | Configuration template |
| `configs/mcp-templates/crawl4ai-mcp-config.json` | MCP configuration |
| `.agents/tools/browser/crawl4ai.md` | Main guide |
| `.agents/tools/browser/crawl4ai-integration.md` | Integration guide |
| `.agents/tools/browser/crawl4ai-usage.md` | Usage guide |

## MCP Server Setup

NPM: https://www.npmjs.com/package/crawl4ai-mcp-server
Docs: https://docs.crawl4ai.com/core/docker-deployment/#mcp-model-context-protocol-support

Claude Desktop config:

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

## Docker

- **Latest**: `unclecode/crawl4ai:latest` | **Pinned**: `unclecode/crawl4ai:0.7.7`
- **Architectures**: AMD64, ARM64
- **Compose**: https://github.com/unclecode/crawl4ai/blob/main/docker-compose.yml
- **Env vars**: https://docs.crawl4ai.com/core/docker-deployment/#environment-setup-api-keys
- **Shared memory**: `--shm-size=1g` recommended

## API Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/crawl` | Synchronous crawling |
| POST | `/crawl/job` | Async crawling with webhooks |
| POST | `/llm/job` | LLM extraction with webhooks |
| GET | `/job/{task_id}` | Check job status |
| GET | `/health` | Service health check |
| GET | `/metrics` | Prometheus metrics |
| GET | `/schema` | API schema documentation |
| GET | `/dashboard` | Monitoring dashboard |
| GET | `/playground` | Interactive testing |
| POST | `/screenshot` | Capture page screenshots |
| POST | `/pdf` | Generate PDF from webpage |
| POST | `/html` | Extract raw HTML |
| POST | `/js` | Execute JavaScript on page |

## Operational Notes

- **Security**: Built-in rate limiting, robots.txt respect, configurable timeouts. Supports JWT auth, API key management, webhook auth headers.
- **Monitoring**: Dashboard shows CPU/memory/network, request analytics, browser pool status, job queue. Native Prometheus metrics.
- **Performance**: Tune browser pool size, concurrent requests, memory cleanup intervals, and cache modes per use case. Set Docker CPU/memory limits.
- **Auth**: JWT for API access, API keys for LLM providers, custom headers for webhooks.

## Version History

| Version | Highlights |
|---------|------------|
| v0.7.7 | Self-hosting platform with real-time monitoring |
| v0.7.6 | Complete webhook infrastructure for job queue API |
| v0.7.5 | Docker hooks system with function-based API |
| v0.7.4 | Intelligent table extraction & performance updates |
