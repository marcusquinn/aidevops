---
description: Advanced MCP integrations for AI DevOps
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
---

# Advanced MCP Integrations for AI DevOps

<!-- AI-CONTEXT-START -->

## Quick Reference

**Setup All**: `bash .agents/scripts/setup-mcp-integrations.sh all`
**Validate**: `bash .agents/scripts/validate-mcp-integrations.sh`

**Browser & Web**:
- Chrome DevTools MCP: `claude mcp add chrome-devtools npx chrome-devtools-mcp@latest`
- Playwright MCP: `npm install -g playwright-mcp`
- Cloudflare Browser Rendering: Server-side scraping

**SEO & Research**:
- Ahrefs MCP: `AHREFS_API_KEY` required
- Perplexity MCP: `PERPLEXITY_API_KEY` required
- Google Search Console: `GOOGLE_APPLICATION_CREDENTIALS` (service account JSON)

**Document Processing**:
- Unstract MCP: `UNSTRACT_API_KEY` + `API_BASE_URL` required (Docker-based, self-hosted default)

**Mobile Testing**:
- iOS Simulator MCP: AI-driven iOS simulator interaction (tap, swipe, screenshot)

**Development**:
- Claude Code MCP: Claude Code automation (forked server)
- Next.js DevTools MCP
- Context7 MCP: Real-time library docs
- LocalWP MCP: WordPress database access

**Config Location**: `configs/mcp-templates/`
<!-- AI-CONTEXT-END -->

This document provides comprehensive setup and usage instructions for advanced Model Context Protocol (MCP) integrations that dramatically expand our AI development capabilities.

## 📋 **Available MCP Integrations**

### **🌐 Web & Browser Automation**

- **Chrome DevTools MCP**: Browser automation, debugging, performance analysis
- **Playwright MCP**: Cross-browser testing and automation
- **Cloudflare Browser Rendering**: Server-side web scraping and rendering

### **🔍 SEO & Research Tools**

- **Ahrefs MCP**: SEO analysis, backlink research, keyword data
- **Perplexity MCP**: AI-powered web search and research
- **Google Search Console MCP**: Search performance data and insights

### **📱 Mobile Testing**

- **iOS Simulator MCP**: AI-driven iOS simulator interaction (tap, swipe, type, screenshot, accessibility)

### **⚡ Development Tools**

- **Claude Code MCP**: Run Claude Code as an MCP server for automation
- **Next.js DevTools MCP**: Next.js development and debugging assistance

### **📄 Document Processing**

- **Unstract MCP**: LLM-powered structured data extraction from unstructured documents (PDF, images, DOCX)

### **📧 CRM & Marketing**

- **FluentCRM MCP**: WordPress CRM with contacts, campaigns, automations, and email marketing

### **📚 Legacy MCP Servers (from MCP-SERVERS.md)**

- **Context7 MCP**: Real-time documentation access for development libraries
- **LocalWP MCP**: Direct WordPress database access for local development

## 🎯 **Quick Setup Commands**

### **Chrome DevTools MCP**

```bash
# Add to Claude Desktop
claude mcp add chrome-devtools npx chrome-devtools-mcp@latest

# Add to VS Code Copilot
code --add-mcp '{"name":"chrome-devtools","command":"npx","args":["chrome-devtools-mcp@latest"]}'

# Manual configuration
npx chrome-devtools-mcp@latest --channel=canary --headless=true
```

### **Playwright MCP**

```bash
# Install Playwright MCP
npm install -g playwright-mcp
playwright-mcp --install-browsers

# Add to MCP client
claude mcp add playwright npx playwright-mcp@latest
```

### **iOS Simulator MCP**

```bash
# Prerequisites: macOS, Xcode with iOS simulators, Facebook IDB
brew tap facebook/fb && brew install idb-companion

# Add to Claude Code
claude mcp add ios-simulator npx ios-simulator-mcp
```

**Tools**: `ui_tap`, `ui_swipe`, `ui_type`, `ui_view`, `screenshot`, `record_video`, `ui_describe_all`, `install_app`, `launch_app`, `get_booted_sim_id`.

**Env vars**: `IOS_SIMULATOR_MCP_DEFAULT_OUTPUT_DIR` (output dir), `IOS_SIMULATOR_MCP_FILTERED_TOOLS` (disable tools), `IOS_SIMULATOR_MCP_IDB_PATH` (custom IDB path).

**Per-Agent Enablement**: The `tools/mobile/ios-simulator-mcp.md` subagent has `ios-simulator_*: true` in its tools section. Disabled globally, enabled on-demand.

See `tools/mobile/ios-simulator-mcp.md` for detailed documentation.

### **Claude Code MCP (Fork)**

```bash
# Add forked MCP server via Claude Code CLI
claude mcp add claude-code-mcp "npx -y github:marcusquinn/claude-code-mcp"
```

**One-time setup**: run `claude --dangerously-skip-permissions` and accept prompts.
**Upstream**: https://github.com/steipete/claude-code-mcp (revert if merged).
**Local dev (optional)**: clone the fork and swap the command to `./start.sh` for instant iteration.

### **Ahrefs MCP**

```bash
# Get your standard 40-char API key (NOT JWT tokens) from https://ahrefs.com/api
# Store in ~/.config/aidevops/credentials.sh:
export AHREFS_API_KEY="your_40_char_api_key"

# For Claude Desktop:
claude mcp add ahrefs npx @ahrefs/mcp@latest
```

**Important**: The `@ahrefs/mcp` package expects `API_KEY` environment variable, not `AHREFS_API_KEY`.

**For OpenCode** - use bash wrapper pattern (environment blocks don't expand variables):

```json
{
  "ahrefs": {
    "type": "local",
    "command": ["/bin/bash", "-c", "API_KEY=$AHREFS_API_KEY /opt/homebrew/bin/npx -y @ahrefs/mcp@latest"],
    "enabled": true
  }
}
```

### **Perplexity MCP**

```bash
# Setup Perplexity integration
export PERPLEXITY_API_KEY="your_api_key_here"
claude mcp add perplexity npx perplexity-mcp@latest
```

### **Google Search Console MCP**

```bash
# Setup Google Search Console integration
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account-key.json"
claude mcp add google-search-console npx mcp-server-gsc@latest
```

### **FluentCRM MCP**

**Note**: The FluentCRM MCP server is not published to npm. It requires cloning and building locally.

```bash
# 1. Clone and build the MCP server
mkdir -p ~/.local/share/mcp-servers
cd ~/.local/share/mcp-servers
git clone https://github.com/netflyapp/fluentcrm-mcp-server.git
cd fluentcrm-mcp-server
npm install
npm run build

# 2. Store credentials in ~/.config/aidevops/credentials.sh:
export FLUENTCRM_API_URL="https://your-domain.com/wp-json/fluent-crm/v2"
export FLUENTCRM_API_USERNAME="your_username"
export FLUENTCRM_API_PASSWORD="your_application_password"
```

**For OpenCode** - use bash wrapper pattern (disabled globally, enabled per-agent):

```json
{
  "fluentcrm": {
    "type": "local",
    "command": ["/bin/bash", "-c", "source ~/.config/aidevops/credentials.sh && node ~/.local/share/mcp-servers/fluentcrm-mcp-server/dist/fluentcrm-mcp-server.js"],
    "enabled": false
  }
}
```

**For Claude Desktop**:

```json
{
  "mcpServers": {
    "fluentcrm": {
      "command": "node",
      "args": ["~/.local/share/mcp-servers/fluentcrm-mcp-server/dist/fluentcrm-mcp-server.js"],
      "env": {
        "FLUENTCRM_API_URL": "https://your-domain.com/wp-json/fluent-crm/v2",
        "FLUENTCRM_API_USERNAME": "your_username",
        "FLUENTCRM_API_PASSWORD": "your_application_password"
      }
    }
  }
}
```

**Per-Agent Enablement**: The `services/crm/fluentcrm.md` subagent has `fluentcrm_*: true` in its tools section. Main agents (`sales.md`, `marketing.md`) reference this subagent for CRM operations.

**Available Tools**: Contacts, Tags, Lists, Campaigns, Email Templates, Automations, Webhooks, Smart Links, Dashboard Stats.

See `services/crm/fluentcrm.md` for detailed documentation.

### **Unstract MCP**

```bash
# 1. Self-hosted (recommended): unstract-helper.sh install
# 2. Or cloud: Sign up at https://unstract.com/start-for-free/
# 3. Create a Prompt Studio project, define schema, deploy as API
# 4. Store credentials in ~/.config/aidevops/credentials.sh:
export UNSTRACT_API_KEY="your_api_key_here"
export API_BASE_URL="http://backend.unstract.localhost/deployment/api/your-id/"
chmod 600 ~/.config/aidevops/credentials.sh
```

**Note**: The MCP expects `API_BASE_URL` (not prefixed) - this matches the official Unstract spec.

**For OpenCode** - Docker-based, disabled globally, enabled on-demand:

```json
{
  "unstract": {
    "type": "local",
    "command": ["/bin/bash", "-c", "source ~/.config/aidevops/credentials.sh && docker run -i --rm -v /tmp:/tmp -e UNSTRACT_API_KEY -e API_BASE_URL -e DISABLE_TELEMETRY=true unstract/mcp-server:${UNSTRACT_IMAGE_TAG:-latest} unstract"],
    "enabled": false
  }
}
```

**For Claude Desktop** (Docker):

```json
{
  "mcpServers": {
    "unstract_tool": {
      "command": "/usr/local/bin/docker",
      "args": [
        "run", "-i", "--rm",
        "-v", "/tmp:/tmp",
        "-e", "UNSTRACT_API_KEY",
        "-e", "API_BASE_URL",
        "-e", "DISABLE_TELEMETRY=true",
        "unstract/mcp-server", "unstract"
      ],
      "env": {
        "UNSTRACT_API_KEY": "your_api_key",
        "API_BASE_URL": "http://backend.unstract.localhost/deployment/api/.../"
      }
    }
  }
}
```

**Per-Agent Enablement**: The `services/document-processing/unstract.md` subagent has `unstract_tool: true` in its tools section. Agents needing document extraction reference this subagent.

**Available Tools**: `unstract_tool` - submits files, polls for completion, returns structured JSON. Supports optional metadata and metrics.

**Image Pinning**: Set `UNSTRACT_IMAGE_TAG` env var to pin a specific version for reproducibility.

See `services/document-processing/unstract.md` for detailed documentation.

## 🔧 **Configuration Examples**

### **Advanced Chrome DevTools Configuration**

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
        "--logFile=/tmp/chrome-mcp.log"
      ]
    }
  }
}
```

### **Cloudflare Browser Rendering Configuration**

```json
{
  "mcpServers": {
    "cloudflare-browser": {
      "command": "npx",
      "args": [
        "cloudflare-browser-rendering-mcp@latest",
        "--account-id=your_account_id",
        "--api-token=your_api_token"
      ]
    }
  }
}
```

## 📊 **Use Cases & Examples**

### **Web Scraping & Analysis**

- Extract data from websites using Chrome DevTools or Cloudflare Browser Rendering
- Perform SEO analysis with Ahrefs integration
- Research topics and gather information with Perplexity

### **Automated Testing**

- Cross-browser testing with Playwright
- Performance analysis with Chrome DevTools
- Visual regression testing and debugging

### **Development Assistance**

- Next.js development debugging and optimization
- Real-time browser inspection and manipulation
- API testing and validation

## 🔐 **Security & API Keys**

### **Required API Keys**

- **Ahrefs**: Get standard 40-char key from [Ahrefs API Dashboard](https://ahrefs.com/api) (JWT tokens don't work)
- **Perplexity**: Get from [Perplexity API](https://docs.perplexity.ai/)
- **Cloudflare**: Account ID and API token from Cloudflare dashboard

### **Environment Variables**

```bash
# Ahrefs - store as AHREFS_API_KEY, MCP receives it as API_KEY via bash wrapper
export AHREFS_API_KEY="your_40_char_ahrefs_key"
export PERPLEXITY_API_KEY="your_perplexity_key"
export CLOUDFLARE_ACCOUNT_ID="your_account_id"
export CLOUDFLARE_API_TOKEN="your_api_token"

# Unstract - document processing (see services/document-processing/unstract.md)
export UNSTRACT_API_KEY="your_unstract_api_key"
export API_BASE_URL="http://backend.unstract.localhost/deployment/api/your-id/"
# Optional: pin image version for reproducibility
export UNSTRACT_IMAGE_TAG="latest"
```

## 🚀 **Getting Started**

### **Quick Setup (All Integrations)**

```bash
# Install all MCP integrations
bash .agents/scripts/setup-mcp-integrations.sh all

# Validate setup
bash .agents/scripts/validate-mcp-integrations.sh
```

### **Individual Integration Setup**

```bash
# Install specific integration
bash .agents/scripts/setup-mcp-integrations.sh chrome-devtools
bash .agents/scripts/setup-mcp-integrations.sh playwright
bash .agents/scripts/setup-mcp-integrations.sh ahrefs
```

### **Configuration Steps**

1. **Choose your MCP integrations** based on your needs
2. **Run the setup script** for your selected integrations
3. **Configure API keys** using the provided templates
4. **Test integrations** with the validation script
5. **Start using** advanced AI-assisted development capabilities!

## 🎯 **Real-World Use Cases**

### **Web Development Workflow**

- **Chrome DevTools**: Debug performance issues, analyze Core Web Vitals
- **Playwright**: Automated cross-browser testing and E2E validation
- **Next.js DevTools**: Real-time development assistance and optimization

### **SEO & Content Strategy**

- **Ahrefs**: Keyword research, backlink analysis, competitor insights
- **Perplexity**: AI-powered research and content ideation
- **Cloudflare Browser Rendering**: Server-side content analysis

### **Quality Assurance**

- **Playwright**: Comprehensive test automation across browsers
- **Chrome DevTools**: Performance monitoring and debugging
- **Visual regression testing** with screenshot comparisons

## 📊 **Integration Status Dashboard**

Run the validation script to see your current setup status:

```bash
bash .agents/scripts/validate-mcp-integrations.sh
```

Expected output for fully configured setup:

```text
✅ Overall status: EXCELLENT (100% success rate)
✅ All MCP integrations are ready to use!
```

## 📚 **Additional Resources**

- [MCP Integration Setup Script](.agents/scripts/setup-mcp-integrations.sh)
- [MCP Validation Script](.agents/scripts/validate-mcp-integrations.sh)
- [MCP Configuration Templates](configs/mcp-templates/)
- [Chrome DevTools Guide](.agents/tools/browser/chrome-devtools.md)
- [Playwright Automation Guide](.agents/tools/browser/playwright.md)
- [Troubleshooting Guide](.agents/aidevops/mcp-troubleshooting.md)
