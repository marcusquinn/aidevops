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
- Cloudflare Code Mode MCP: Workers, D1, KV, R2, Pages, AI Gateway via OAuth
- MCPorter: Discover, call, compose, and generate CLIs/typed clients for MCP servers
- OpenAPI Search MCP: Search and explore any OpenAPI spec — zero install, remote Cloudflare Worker

**Config Location**: `configs/mcp-templates/`

**Security**: MCP servers are a trust boundary -- they access conversation context, credentials, and network. Verify source, scan dependencies (`npx @socketsecurity/cli npm info <pkg>`), and scan source (`skill-scanner scan /path`) before installing. See `tools/mcp-toolkit/mcporter.md` "Security Considerations".
<!-- AI-CONTEXT-END -->

## Setup Commands

### Chrome DevTools MCP

```bash
claude mcp add chrome-devtools npx chrome-devtools-mcp@latest
# VS Code: code --add-mcp '{"name":"chrome-devtools","command":"npx","args":["chrome-devtools-mcp@latest"]}'
```

### Playwright MCP

```bash
npm install -g playwright-mcp
playwright-mcp --install-browsers
claude mcp add playwright npx playwright-mcp@latest
```

### iOS Simulator MCP

```bash
# Prerequisites: macOS, Xcode with iOS simulators, Facebook IDB
brew tap facebook/fb && brew install idb-companion
claude mcp add ios-simulator npx ios-simulator-mcp
```

**Tools**: `ui_tap`, `ui_swipe`, `ui_type`, `ui_view`, `screenshot`, `record_video`, `ui_describe_all`, `install_app`, `launch_app`, `get_booted_sim_id`.

**Env vars**: `IOS_SIMULATOR_MCP_DEFAULT_OUTPUT_DIR`, `IOS_SIMULATOR_MCP_FILTERED_TOOLS`, `IOS_SIMULATOR_MCP_IDB_PATH`.

Per-agent enablement: `tools/mobile/ios-simulator-mcp.md` (disabled globally, enabled on-demand).

### Claude Code MCP (Fork)

```bash
claude mcp add claude-code-mcp "npx -y github:marcusquinn/claude-code-mcp"
```

**One-time setup**: run `claude --dangerously-skip-permissions` and accept prompts.
**Upstream**: https://github.com/steipete/claude-code-mcp (revert if merged).

### MCPorter

```bash
npx mcporter list          # Zero-install
pnpm add mcporter          # Project dependency
brew tap steipete/tap && brew install steipete/tap/mcporter
```

**Core commands**: `list` (discover), `call` (invoke), `generate-cli` (mint CLIs), `emit-ts` (typed clients), `auth` (OAuth), `daemon` (keep warm).

Auto-imports configs from Claude Code, Claude Desktop, Cursor, Codex, Windsurf, OpenCode, VS Code.

See `tools/mcp-toolkit/mcporter.md` for full documentation.

### OpenAPI Search MCP

No installation — remote Cloudflare Worker, no auth required.

```bash
# Claude Code
claude mcp add --scope user openapi-search --transport http https://openapi-mcp.openapisearch.com/mcp
```

**OpenCode** (`~/.config/opencode/opencode.json`):

```json
{
  "mcp": {
    "openapi-search": {
      "type": "remote",
      "url": "https://openapi-mcp.openapisearch.com/mcp",
      "enabled": false
    }
  }
}
```

**Claude Desktop** config paths: macOS `~/Library/Application Support/Claude/claude_desktop_config.json`, Windows `%APPDATA%\Claude\claude_desktop_config.json`, Linux `~/.config/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "openapi-search": {
      "type": "http",
      "url": "https://openapi-mcp.openapisearch.com/mcp"
    }
  }
}
```

**Tools**: `searchAPIs` (3000+ public APIs), `getAPIOverview`, `getOperationDetails`. Workflow: search → overview → details (minimal context usage).

Per-agent enablement: `tools/context/openapi-search.md` (disabled globally, enabled on-demand).

### Cloudflare Code Mode MCP

No installation — remote server, OAuth-authenticated.

```json
{ "cloudflare-api": { "url": "https://mcp.cloudflare.com/mcp" } }
```

First connection opens browser OAuth flow to `dash.cloudflare.com`. Token stored automatically.

**OpenCode** (`~/.config/opencode/config.json`):

```json
{
  "mcp": {
    "cloudflare-api": {
      "type": "remote",
      "url": "https://mcp.cloudflare.com/mcp"
    }
  }
}
```

**Tools**: Workers (deploy/update/tail), D1 (SQL), KV (get/put/delete/list), R2 (objects/buckets), Pages (projects/deployments), AI Gateway (logs/analytics), DNS, zone analytics.

Per-agent enablement: `tools/api/cloudflare-mcp.md` (disabled globally, enabled on-demand).

### Ahrefs MCP

```bash
# Store in ~/.config/aidevops/credentials.sh:
export AHREFS_API_KEY="your_40_char_api_key"
claude mcp add ahrefs npx @ahrefs/mcp@latest
```

**Important**: Package expects `API_KEY` env var, not `AHREFS_API_KEY`. Use bash wrapper for OpenCode (env blocks don't expand variables):

```json
{
  "ahrefs": {
    "type": "local",
    "command": ["/bin/bash", "-c", "API_KEY=$AHREFS_API_KEY /opt/homebrew/bin/npx -y @ahrefs/mcp@latest"],
    "enabled": true
  }
}
```

### Perplexity MCP

```bash
export PERPLEXITY_API_KEY="your_api_key_here"
claude mcp add perplexity npx perplexity-mcp@latest
```

### Google Search Console MCP

```bash
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account-key.json"
claude mcp add google-search-console npx mcp-server-gsc@latest
```

### FluentCRM MCP

Not published to npm — requires local build:

```bash
mkdir -p ~/.local/share/mcp-servers
cd ~/.local/share/mcp-servers
git clone https://github.com/netflyapp/fluentcrm-mcp-server.git
cd fluentcrm-mcp-server && npm install && npm run build

# Store in ~/.config/aidevops/credentials.sh:
export FLUENTCRM_API_URL="https://your-domain.com/wp-json/fluent-crm/v2"
export FLUENTCRM_API_USERNAME="your_username"
export FLUENTCRM_API_PASSWORD="your_application_password"
```

**OpenCode** (bash wrapper, disabled globally):

```json
{
  "fluentcrm": {
    "type": "local",
    "command": ["/bin/bash", "-c", "source ~/.config/aidevops/credentials.sh && node ~/.local/share/mcp-servers/fluentcrm-mcp-server/dist/fluentcrm-mcp-server.js"],
    "enabled": false
  }
}
```

Per-agent enablement: `services/crm/fluentcrm.md`. Tools: Contacts, Tags, Lists, Campaigns, Email Templates, Automations, Webhooks, Smart Links, Dashboard Stats.

### Unstract MCP

```bash
# Self-hosted (recommended): unstract-helper.sh install
# Or cloud: https://unstract.com/start-for-free/
# Store in ~/.config/aidevops/credentials.sh:
export UNSTRACT_API_KEY="your_api_key_here"
export API_BASE_URL="http://backend.unstract.localhost/deployment/api/your-id/"
```

**OpenCode** (Docker, disabled globally):

```json
{
  "unstract": {
    "type": "local",
    "command": ["/bin/bash", "-c", "source ~/.config/aidevops/credentials.sh && docker run -i --rm -v /tmp:/tmp -e UNSTRACT_API_KEY -e API_BASE_URL -e DISABLE_TELEMETRY=true unstract/mcp-server:${UNSTRACT_IMAGE_TAG:-latest} unstract"],
    "enabled": false
  }
}
```

**Tool**: `unstract_tool` — submits files, polls for completion, returns structured JSON. Set `UNSTRACT_IMAGE_TAG` to pin version.

Per-agent enablement: `services/document-processing/unstract.md`.

## Advanced Configurations

### Chrome DevTools (full options)

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": ["chrome-devtools-mcp@latest", "--channel=canary", "--headless=true", "--isolated=true", "--viewport=1920x1080", "--logFile=/tmp/chrome-mcp.log"]
    }
  }
}
```

### Cloudflare Browser Rendering

```json
{
  "mcpServers": {
    "cloudflare-browser": {
      "command": "npx",
      "args": ["cloudflare-browser-rendering-mcp@latest", "--account-id=your_account_id", "--api-token=your_api_token"]
    }
  }
}
```

## Environment Variables

```bash
export AHREFS_API_KEY="your_40_char_ahrefs_key"   # MCP receives as API_KEY via bash wrapper
export PERPLEXITY_API_KEY="your_perplexity_key"
export CLOUDFLARE_ACCOUNT_ID="your_account_id"
export CLOUDFLARE_API_TOKEN="your_api_token"
export UNSTRACT_API_KEY="your_unstract_api_key"
export API_BASE_URL="http://backend.unstract.localhost/deployment/api/your-id/"
export UNSTRACT_IMAGE_TAG="latest"                 # Optional: pin image version
```

## Validation

```bash
bash .agents/scripts/validate-mcp-integrations.sh
# Expected: ✅ Overall status: EXCELLENT (100% success rate)
```

## Resources

- [Setup Script](.agents/scripts/setup-mcp-integrations.sh)
- [Validation Script](.agents/scripts/validate-mcp-integrations.sh)
- [Config Templates](configs/mcp-templates/)
- [Chrome DevTools Guide](.agents/tools/browser/chrome-devtools.md)
- [Playwright Guide](.agents/tools/browser/playwright.md)
- [Troubleshooting](.agents/aidevops/mcp-troubleshooting.md)
