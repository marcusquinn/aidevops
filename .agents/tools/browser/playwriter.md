---
description: Playwriter MCP - browser automation via Chrome extension with full Playwright API
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
mcp:
  - playwriter
---

# Playwriter - Browser Extension MCP

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Browser automation via Chrome extension with full Playwright API
- **Extension**: [Chrome Web Store](https://chromewebstore.google.com/detail/playwriter-mcp/jfeammnjpkecdekppnclgkkffahnhfhe) (Chrome, Brave, Edge)
- **MCP**: `npx playwriter@latest`
- **Single Tool**: `execute` — runs Playwright code snippets
- **Icon States**: Gray/Black = disconnected · Green = ready · Orange = connecting · Red = error
- **Performance**: Navigate 2.95s, form fill 2.24s, reliability 1.96s avg. Always headed.

**Why Playwriter over alternatives:**

| Feature | Playwriter | BrowserMCP | Playwright MCP | Stagehand |
|---------|------------|------------|----------------|-----------|
| Tools | 1 (`execute`) | 17+ | 10+ | 4 primitives |
| Context bloat | Minimal | High | Medium | Low |
| API | Full Playwright | Limited | Full Playwright | Natural language |
| Browser | Your existing | New instance | New instance | New instance |
| Extensions | Yes | No | No | No |
| Sessions/cookies | Yes | No | No | No |
| Detection bypass | Yes (disconnect) | No | No | No |

**When to use**: Existing logged-in sessions, browser extensions (password managers, ad blockers), collaborating with AI past captchas, resource efficiency.

**When to use alternatives**: **Stagehand** for natural language automation / self-healing selectors. **Playwright MCP** for isolated automation without extension. **Crawl4AI** for scraping. **playwright-cli** for headless (no MCP needed).

**Parallel tabs**: Click extension on each tab. Shared session — not isolated. For isolated parallel work, use Playwright direct.

**Chrome DevTools MCP**: `chrome://inspect/#remote-debugging` → `npx chrome-devtools-mcp@latest --autoConnect`.

<!-- AI-CONTEXT-END -->

## Installation

1. **Extension**: Install from [Chrome Web Store](https://chromewebstore.google.com/detail/playwriter-mcp/jfeammnjpkecdekppnclgkkffahnhfhe). Pin to toolbar. Edge: enable "Allow extensions from other stores" in `edge://extensions` first.
2. **Connect**: Click extension icon on tabs to control. Green = connected.
3. **MCP config**:

**Claude Desktop** (`claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "playwriter": {
      "command": "npx",
      "args": ["-y", "playwriter@latest"]
    }
  }
}
```

**OpenCode** (`~/.config/opencode/opencode.json`) — use full path to `npx` (e.g., `/opt/homebrew/bin/npx`) if the app runs with a restricted PATH:

```json
{
  "mcp": {
    "playwriter": {
      "type": "local",
      "command": ["/opt/homebrew/bin/npx", "-y", "playwriter@latest"],
      "enabled": true
    }
  }
}
```

**Per-agent enable** (OpenCode):

```json
{
  "tools": { "playwriter_*": false },
  "agent": {
    "Build+": { "tools": { "playwriter_*": true } }
  }
}
```

## Usage

### The `execute` Tool

Runs any Playwright code against connected tabs:

```javascript
await page.goto('https://example.com')
await page.click('button.submit')
await page.fill('input[name="email"]', 'user@example.com')
await page.screenshot({ path: 'screenshot.png' })
const title = await page.textContent('h1')
await page.waitForSelector('.loaded')
```

### Multi-Tab

```javascript
const pages = context.pages()
const page1 = pages[0]
const newPage = await context.newPage()
await newPage.goto('https://example.com')
```

### Programmatic (without MCP)

```javascript
import { chromium } from 'playwright-core'
import { startPlayWriterCDPRelayServer, getCdpUrl } from 'playwriter'

const server = await startPlayWriterCDPRelayServer()
const browser = await chromium.connectOverCDP(getCdpUrl())
const page = browser.contexts()[0].pages()[0]
await page.goto('https://example.com')
await page.screenshot({ path: 'screenshot.png' })
await browser.close()
server.close()
```

### Screenshots and PDF

> **Screenshot size limit**: Do NOT use `fullPage: true` for AI vision review. Full-page captures can exceed 8000px, crashing the session (Anthropic hard-rejects >8000px). Use viewport-sized screenshots. For human-only full-page: `magick full.png -resize "1568x1568>" full-resized.png`. See `prompts/build.txt` "Screenshot Size Limits".

```javascript
// Viewport screenshot (safe for AI review)
await page.screenshot({ path: 'viewport.png' })

// Element screenshot (safe — scoped, not full page)
await page.locator('.chart').screenshot({ path: 'chart.png' })

// PDF export
await page.pdf({ path: 'page.pdf', format: 'A4' })
```

## Security

- **Local WebSocket** on `localhost:19988` — no CORS, only local processes connect
- **User-controlled** — only tabs where you clicked the extension are accessible
- **Explicit consent** — Chrome shows automation banner on controlled tabs
- New tabs from automation are controlled; unconnected tabs and remote access are not possible

## Troubleshooting

- **Extension not connecting**: Installed and pinned? Click icon on tab (should turn green). Red badge = error. Reload tab.
- **MCP not finding tabs**: Green icon? Restart MCP client. Verify WebSocket on port 19988.
- **Automation detection**: Disconnect (click icon → gray) → complete manual action (login, captcha) → reconnect (click → green) → resume.

## Resources

- **GitHub**: https://github.com/remorses/playwriter
- **Chrome Extension**: https://chromewebstore.google.com/detail/playwriter-mcp/jfeammnjpkecdekppnclgkkffahnhfhe
- **Playwright Docs**: https://playwright.dev/docs/api/class-page
