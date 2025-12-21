---
description: Browser automation tool selection and usage guide
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

# Browser Automation - Tool Selection Guide

<!-- AI-CONTEXT-START -->

## Default Tool: Dev-Browser

**ALWAYS try dev-browser first** for any browser automation task. It's the fastest, cheapest, and most capable option.

```bash
# Setup (one-time)
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh setup

# Start server (required before use)
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start
```

**Why dev-browser is default**:
- **14% faster, 39% cheaper** than alternatives (benchmarked)
- **Stateful**: Pages persist across script executions
- **Codebase-aware**: Read source code to write selectors directly
- **LLM-friendly**: ARIA snapshots for element discovery

## Tool Selection Decision Tree

```text
Need browser automation?
    │
    ├─► Dev-browser running? ──► YES ──► Use dev-browser (default)
    │                              │
    │                              └─► NO ──► Start it: dev-browser-helper.sh start
    │
    ├─► Need existing browser session/cookies? ──► Use Playwriter
    │
    ├─► Need natural language control? ──► Use Stagehand
    │
    └─► Need web crawling/extraction? ──► Use Crawl4AI
```

## Quick Reference

| Tool | Best For | Setup |
|------|----------|-------|
| **dev-browser** (DEFAULT) | Dev testing, multi-step workflows | `dev-browser-helper.sh setup` |
| **playwriter** | Existing sessions, bypass detection | Chrome extension + MCP |
| **stagehand** | Natural language automation | `stagehand-helper.sh setup` |
| **crawl4ai** | Web scraping, content extraction | `crawl4ai-helper.sh setup` |
| **playwright** | Cross-browser testing | MCP integration |

**Full docs**: `tools/browser/dev-browser.md` (default), `tools/browser/playwriter.md`, etc.

**Ethical Rules**: Respect ToS, rate limit (2-5s delays), no spam, legitimate use only
<!-- AI-CONTEXT-END -->

## Dev-Browser Usage (Default)

**Always start here** - dev-browser handles most browser automation needs.

### Quick Start

```bash
# 1. Start server (if not running)
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start

# 2. Execute automation script
cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx <<'EOF'
import { connect, waitForPageLoad } from "@/client.js";
const client = await connect("http://localhost:9222");
const page = await client.page("main");
await page.goto("http://localhost:3000");
await waitForPageLoad(page);
console.log({ title: await page.title(), url: page.url() });
await client.disconnect();
EOF
```

### Common Patterns

**Navigate and interact**:

```bash
cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx <<'EOF'
import { connect, waitForPageLoad } from "@/client.js";
const client = await connect("http://localhost:9222");
const page = await client.page("main");
await page.goto("http://localhost:3000/login");
await page.fill('input[name="email"]', 'user@example.com');
await page.fill('input[name="password"]', 'password');
await page.click('button[type="submit"]');
await waitForPageLoad(page);
console.log("Logged in:", page.url());
await client.disconnect();
EOF
```

**Get ARIA snapshot** (for unknown pages):

```bash
cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx <<'EOF'
import { connect, waitForPageLoad } from "@/client.js";
const client = await connect("http://localhost:9222");
const page = await client.page("main");
await page.goto("https://example.com");
await waitForPageLoad(page);
const snapshot = await client.getAISnapshot("main");
console.log(snapshot);
await client.disconnect();
EOF
```

**Full documentation**: `tools/browser/dev-browser.md`

## Alternative Tools

Use these when dev-browser doesn't fit the use case:

### Playwriter - Chrome Extension MCP

**Browser automation via Chrome extension with full Playwright API - minimal context bloat**

```bash
# 1. Install Chrome extension
# https://chromewebstore.google.com/detail/playwriter-mcp/jfeammnjpkecdekppnclgkkffahnhfhe

# 2. Add to MCP config (OpenCode)
# "playwriter": { "type": "local", "command": ["npx", "playwriter@latest"] }

# 3. Click extension icon on tabs to control (turns green)
```

**Key Advantages**:
- **1 tool vs 17+** - Single `execute` tool runs Playwright code
- **Your existing browser** - Reuse sessions, extensions, cookies
- **Bypass detection** - Disconnect extension to bypass automation detection
- **Collaborate with AI** - Work alongside it, help with captchas

See `tools/browser/playwriter.md` for full documentation.

### **🤘 Stagehand AI Browser Automation**

**Revolutionary AI-powered browser automation with natural language control - Available in JavaScript and Python**

#### **JavaScript Version**

```bash
# Quick setup
bash .agent/scripts/stagehand-helper.sh setup

# MCP integration
bash .agent/scripts/setup-mcp-integrations.sh stagehand

# Run examples
cd ~/.aidevops/stagehand
npm run search-products "wireless headphones"
npm run analyze-linkedin
```

#### **Python Version** 🐍 **NEW**

```bash
# Quick setup
bash .agent/scripts/stagehand-python-helper.sh setup

# MCP integration
bash .agent/scripts/setup-mcp-integrations.sh stagehand-python

# Run examples
source ~/.aidevops/stagehand-python/.venv/bin/activate
python examples/basic_example.py
python examples/ecommerce_automation.py "wireless headphones"
```

#### **Both Versions**

```bash
# Setup both JavaScript and Python
bash .agent/scripts/setup-mcp-integrations.sh stagehand-both
```

**Key Features**:

- **Natural Language Actions**: `await stagehand.act("click the login button")`
- **Structured Data Extraction**: Extract data with Zod (JS) or Pydantic (Python) schemas
- **Self-Healing Automation**: Adapts when websites change
- **Autonomous Agents**: Complete workflows with AI decision-making
- **Local-First Privacy**: Complete control over browser and data
- **Multi-Language Support**: Choose JavaScript or Python based on your needs

**Perfect for**:

- E-commerce automation and price monitoring
- Social media analytics and engagement
- User journey testing and QA
- Data collection and research with type safety
- Autonomous business process automation
- Data science workflows (Python) or web development (JavaScript)

### **Workflow Integration**

```bash
# Convert documents for agent context
bash .agent/scripts/pandoc-helper.sh batch ./social-media-docs ./agent-ready

# Start Agno with browser automation
~/.aidevops/scripts/start-agno-stack.sh

# Agents can now:
# - Analyze social media strategies from converted documents
# - Automate engagement based on documented guidelines
# - Generate reports and analytics
# - Optimize automation based on performance data
```

### **Version Management Integration**

```bash
# Get current framework version for agent context
VERSION=$(bash .agent/scripts/version-manager.sh get)

# Agents are aware of framework version and capabilities
# Can provide version-specific automation features
```

## 📈 **Benefits for AI DevOps**

- **🤖 Intelligent Automation**: AI-powered decision making for web interactions
- **🔒 Ethical Compliance**: Built-in safety guidelines and rate limiting
- **📊 Analytics Integration**: Comprehensive tracking and reporting
- **🔄 Framework Integration**: Seamless workflow with existing tools
- **🎯 Professional Focus**: Specialized agents for business use cases
- **🛡️ Security First**: Secure credential management and privacy protection

---

**Automate your web presence responsibly with AI-powered browser automation!** 🌐🤖✨

**Remember**: Always use automation ethically and in compliance with platform terms of service. Focus on adding genuine value and maintaining authentic professional relationships.
