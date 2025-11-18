# MCP Integrations

Complete guide to Model Context Protocol (MCP) integrations in the AI DevOps Framework.

## Overview

The framework includes 10 MCP servers that provide real-time integration between AI assistants and various development tools, services, and documentation.

**Benefits**:

- Real-time access to documentation and APIs
- Browser automation and testing capabilities
- SEO analysis and research tools
- Performance monitoring and debugging
- Direct database access for development

## Available MCP Servers

### Web & Browser Automation (3 servers)

#### Chrome DevTools MCP

Browser automation, debugging, and performance analysis.

**Installation**:

```bash
# Add to Claude Desktop
claude mcp add chrome-devtools npx chrome-devtools-mcp@latest

# Or install globally
npm install -g chrome-devtools-mcp
```

**Configuration**:

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": [
        "chrome-devtools-mcp@latest",
        "--channel=canary",
        "--headless=true",
        "--viewport=1920x1080"
      ]
    }
  }
}
```

**Use Cases**:

- Performance debugging
- Core Web Vitals analysis
- JavaScript debugging
- Network monitoring
- DOM manipulation

---

#### Playwright MCP

Cross-browser testing and automation.

**Installation**:

```bash
npm install -g playwright-mcp
playwright-mcp --install-browsers
```

**Configuration**:

```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["playwright-mcp@latest"]
    }
  }
}
```

**Use Cases**:

- E2E testing
- Cross-browser compatibility
- Visual regression testing
- Screenshot automation
- Form testing

---

#### Cloudflare Browser Rendering

Server-side web scraping and rendering.

**Installation**:

```bash
export CLOUDFLARE_ACCOUNT_ID="your_account_id"
export CLOUDFLARE_API_TOKEN="your_api_token"
```

**Configuration**:

```json
{
  "mcpServers": {
    "cloudflare-browser": {
      "command": "npx",
      "args": [
        "cloudflare-browser-rendering-mcp@latest",
        "--account-id=${CLOUDFLARE_ACCOUNT_ID}",
        "--api-token=${CLOUDFLARE_API_TOKEN}"
      ]
    }
  }
}
```

**Use Cases**:

- Server-side web scraping
- JavaScript-heavy page rendering
- Content extraction
- Distributed testing

---

### SEO & Research Tools (3 servers)

#### Ahrefs MCP

SEO analysis, backlink research, and keyword data.

**Installation**:

```bash
export AHREFS_API_KEY="your_api_key"
claude mcp add ahrefs npx ahrefs-mcp@latest
```

**API Key**: Get from [Ahrefs API Dashboard](https://ahrefs.com/api)

**Use Cases**:

- Keyword research
- Backlink analysis
- Competitor analysis
- Domain rating checks
- Content gap analysis

---

#### Perplexity MCP

AI-powered web search and research.

**Installation**:

```bash
export PERPLEXITY_API_KEY="your_api_key"
claude mcp add perplexity npx perplexity-mcp@latest
```

**API Key**: Get from [Perplexity API](https://docs.perplexity.ai/)

**Use Cases**:

- Research automation
- Content ideation
- Fact-checking
- Topic exploration
- Competitive intelligence

---

#### Google Search Console MCP

Search performance data and insights.

**Installation**:

```bash
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account-key.json"
claude mcp add google-search-console npx mcp-server-gsc@latest
```

**Setup**: Requires Google Cloud service account with Search Console API access

**Use Cases**:

- Search performance tracking
- Query analysis
- Click-through rate optimization
- Index status monitoring
- Search appearance insights

---

### Performance & Analytics (1 server)

#### PageSpeed Insights MCP

Website performance auditing and optimization.

**Installation**:

```bash
bash .agent/scripts/setup-mcp-integrations.sh pagespeed
```

**Use Cases**:

- Performance scoring
- Core Web Vitals
- Mobile optimization
- Speed optimization recommendations
- Competitive benchmarking

---

### Development Tools (3 servers)

#### Next.js DevTools MCP

Next.js development and debugging assistance.

**Installation**:

```bash
npm install -g nextjs-devtools-mcp
```

**Use Cases**:

- Route debugging
- SSR/SSG optimization
- Build analysis
- Performance profiling
- API route testing

---

#### Context7 MCP

Real-time documentation access for thousands of libraries.

**Installation**:

```bash
bash .agent/scripts/setup-mcp-integrations.sh context7
```

**Supported Libraries**: React, Vue, Angular, Node.js, Python, and 1000+ more

**Use Cases**:

- API reference lookup
- Code examples
- Best practices
- Migration guides
- Version compatibility

---

#### LocalWP MCP

Direct WordPress database access for local development.

**Installation**:

```bash
bash .agent/scripts/setup-mcp-integrations.sh localwp
```

**Requirements**: Local by Flywheel or similar WordPress environment

**Use Cases**:

- Database queries
- Content management
- Plugin development
- Theme customization
- Debug logging

---

## Quick Setup

### Install All MCP Servers

```bash
# Run comprehensive setup
bash .agent/scripts/setup-mcp-integrations.sh all

# Validate installation
bash .agent/scripts/validate-mcp-integrations.sh
```

### Install Specific Server

```bash
# Chrome DevTools
bash .agent/scripts/setup-mcp-integrations.sh chrome-devtools

# Playwright
bash .agent/scripts/setup-mcp-integrations.sh playwright

# Ahrefs
bash .agent/scripts/setup-mcp-integrations.sh ahrefs

# Context7
bash .agent/scripts/setup-mcp-integrations.sh context7
```

## Configuration

### API Keys Setup

Store API keys securely:

```bash
# Create API keys file
mkdir -p ~/.config/aidevops
touch ~/.config/aidevops/api-keys.txt
chmod 600 ~/.config/aidevops/api-keys.txt

# Add keys
echo "AHREFS_API_KEY=your_key" >> ~/.config/aidevops/api-keys.txt
echo "PERPLEXITY_API_KEY=your_key" >> ~/.config/aidevops/api-keys.txt
echo "CLOUDFLARE_ACCOUNT_ID=your_id" >> ~/.config/aidevops/api-keys.txt
echo "CLOUDFLARE_API_TOKEN=your_token" >> ~/.config/aidevops/api-keys.txt
```

### Environment Variables

```bash
# Load from file
source ~/.config/aidevops/api-keys.txt

# Or set directly
export AHREFS_API_KEY="your_ahrefs_key"
export PERPLEXITY_API_KEY="your_perplexity_key"
export CLOUDFLARE_ACCOUNT_ID="your_account_id"
export CLOUDFLARE_API_TOKEN="your_api_token"
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account.json"
```

### Claude Desktop Configuration

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": ["chrome-devtools-mcp@latest", "--headless=true"]
    },
    "playwright": {
      "command": "npx",
      "args": ["playwright-mcp@latest"]
    },
    "ahrefs": {
      "command": "npx",
      "args": ["ahrefs-mcp@latest"],
      "env": {
        "AHREFS_API_KEY": "${AHREFS_API_KEY}"
      }
    },
    "perplexity": {
      "command": "npx",
      "args": ["perplexity-mcp@latest"],
      "env": {
        "PERPLEXITY_API_KEY": "${PERPLEXITY_API_KEY}"
      }
    },
    "context7": {
      "command": "npx",
      "args": ["context7-mcp@latest"]
    }
  }
}
```

## Usage Examples

### Web Development Workflow

```bash
# 1. Debug performance with Chrome DevTools
# AI: "Analyze performance of https://example.com"

# 2. Run cross-browser tests with Playwright
# AI: "Test login flow across Chrome, Firefox, and Safari"

# 3. Audit with PageSpeed
./providers/pagespeed-helper.sh lighthouse https://example.com

# 4. Look up Next.js best practices
# AI: "Show me Next.js SSR optimization techniques"
```

### SEO Analysis Workflow

```bash
# 1. Research keywords with Ahrefs
# AI: "Find top keywords for 'cloud hosting'"

# 2. Analyze search performance with GSC
# AI: "Show top queries for example.com last 30 days"

# 3. Research with Perplexity
# AI: "Research competitor content strategies for SaaS"

# 4. Scrape competitor pages
# AI: "Extract pricing data from competitor.com"
```

### WordPress Development Workflow

```bash
# 1. Create local site
./providers/localhost-helper.sh create-site mysite.local

# 2. Query database via MCP
# AI: "Show all published posts from last week"

# 3. Look up WordPress hooks
# AI: "Find Context7 documentation for wp_enqueue_scripts"

# 4. Test performance
./providers/pagespeed-helper.sh wordpress https://mysite.local
```

## Real-World Use Cases

### 1. Performance Optimization

**Scenario**: Website is slow, need to identify bottlenecks

**Tools**:

- Chrome DevTools MCP: Analyze runtime performance
- PageSpeed MCP: Get optimization recommendations
- Lighthouse: Comprehensive audit

**Workflow**:

```text
AI: "Analyze performance of https://example.com"
→ Chrome DevTools runs performance profile
→ PageSpeed generates audit
→ AI provides prioritized optimization list
```

---

### 2. SEO Competitive Analysis

**Scenario**: Improve search rankings for target keywords

**Tools**:

- Ahrefs MCP: Keyword and backlink research
- Google Search Console MCP: Current performance data
- Perplexity MCP: Content research

**Workflow**:

```text
AI: "Analyze SEO competition for 'cloud hosting'"
→ Ahrefs finds top-ranking pages
→ GSC shows current ranking position
→ Perplexity researches content gaps
→ AI generates optimization strategy
```

---

### 3. Automated Testing

**Scenario**: Need comprehensive cross-browser testing

**Tools**:

- Playwright MCP: Multi-browser automation
- Chrome DevTools MCP: Debugging
- Visual regression testing

**Workflow**:

```text
AI: "Test checkout flow across all browsers"
→ Playwright runs tests on Chrome, Firefox, Safari
→ Screenshots captured for comparison
→ Chrome DevTools debugs any failures
→ AI reports results with fixes
```

---

### 4. Development Assistance

**Scenario**: Building Next.js app, need real-time help

**Tools**:

- Context7 MCP: Documentation lookup
- Next.js DevTools MCP: Debugging
- Chrome DevTools MCP: Performance

**Workflow**:

```text
AI: "How do I optimize this Next.js page?"
→ Context7 provides Next.js best practices
→ Next.js DevTools analyzes current setup
→ Chrome DevTools profiles performance
→ AI suggests specific improvements
```

## Validation & Testing

### Check Installation Status

```bash
bash .agent/scripts/validate-mcp-integrations.sh
```

**Expected Output**:

```text
✅ Chrome DevTools MCP: Installed
✅ Playwright MCP: Installed
✅ Ahrefs MCP: Configured
✅ Perplexity MCP: Configured
✅ Context7 MCP: Installed
✅ PageSpeed MCP: Installed
✅ LocalWP MCP: Installed

✅ Overall status: EXCELLENT (100% success rate)
✅ All MCP integrations are ready to use!
```

### Test Individual Integration

```bash
# Test Chrome DevTools
npx chrome-devtools-mcp@latest --help

# Test Playwright
npx playwright-mcp@latest --version

# Test Context7
npx context7-mcp@latest search "React useState"
```

## Troubleshooting

### Common Issues

**Problem**: MCP server not starting

**Solution**:

```bash
# Check if port is already in use
lsof -i :port_number

# Restart with debug logging
npx chrome-devtools-mcp@latest --logFile=/tmp/chrome-mcp.log
tail -f /tmp/chrome-mcp.log
```

---

**Problem**: API key not recognized

**Solution**:

```bash
# Verify environment variable is set
echo $AHREFS_API_KEY

# Reload environment
source ~/.config/aidevops/api-keys.txt

# Test API connection
curl -H "Authorization: Bearer $AHREFS_API_KEY" https://api.ahrefs.com/v3/ping
```

---

**Problem**: Chrome not found

**Solution**:

```bash
# Install Chrome Canary
brew install --cask google-chrome-canary

# Or specify Chrome path
npx chrome-devtools-mcp@latest --chromePath=/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome
```

## Best Practices

### Security

- Store API keys in secure files with 600 permissions
- Never commit API keys to repositories
- Use environment variables for sensitive data
- Rotate API keys regularly

### Performance

- Use headless mode for Chrome when possible
- Cache Context7 documentation locally
- Limit concurrent browser instances
- Close MCP servers when not in use

### Development

- Test MCP integrations in isolation first
- Use validation script after configuration changes
- Keep MCP servers updated to latest versions
- Monitor logs for errors and warnings

## Advanced Configuration

### Custom Chrome DevTools Setup

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": [
        "chrome-devtools-mcp@latest",
        "--channel=canary",
        "--headless=true",
        "--isolated=true",
        "--viewport=1920x1080",
        "--userDataDir=/tmp/chrome-mcp-profile",
        "--logFile=/tmp/chrome-mcp.log",
        "--debugPort=9222"
      ]
    }
  }
}
```

### Playwright with Custom Browsers

```bash
# Install specific browsers
playwright-mcp --install-browsers chromium firefox webkit

# Configure custom browser paths
export PLAYWRIGHT_BROWSERS_PATH=/custom/path
```

## Resources

### Official Documentation

- [MCP Protocol Specification](https://modelcontextprotocol.io/)
- [Chrome DevTools MCP](https://github.com/modelcontextprotocol/servers/tree/main/chrome-devtools)
- [Playwright Documentation](https://playwright.dev/)
- [Ahrefs API Docs](https://ahrefs.com/api/documentation)
- [Perplexity API Docs](https://docs.perplexity.ai/)

### Internal Documentation

- [MCP Integration Setup Script](../.agent/scripts/setup-mcp-integrations.sh)
- [MCP Validation Script](../.agent/scripts/validate-mcp-integrations.sh)
- [API Integrations Guide](../docs/API-INTEGRATIONS.md)
- [Browser Automation Guide](../docs/BROWSER-AUTOMATION.md)

---

**Next**: [Configuration Guide →](Configuration.md)
