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
- **Install Extension**: [Chrome Web Store](https://chromewebstore.google.com/detail/playwriter-mcp/jfeammnjpkecdekppnclgkkffahnhfhe)
- **Browsers**: Chrome, Brave, Edge (any Chromium-based browser)
- **MCP**: `npx playwriter@latest`
- **Single Tool**: `execute` - runs Playwright code snippets

**Key Advantages**:
- **1 tool vs 17+** - Less context bloat than BrowserMCP
- **Full Playwright API** - LLMs already know it from training
- **Your existing browser** - Reuse extensions, sessions, cookies; password managers already unlocked
- **Bypass detection** - Disconnect extension to bypass automation detection
- **Proxy via browser** - Uses whatever proxy your browser is configured with
- **Brave** - Built-in Shields; **Edge** - enterprise SSO; **Chrome** - add uBlock Origin

**Performance**: Navigate 2.95s, form fill 2.24s, reliability 1.96s avg. Always headed (visible browser).

**Parallel**: Multiple connected tabs (click extension on each). Shared session — not isolated. For isolated parallel work, use Playwright direct.

**Chrome DevTools MCP**: Enable remote debugging (`chrome://inspect/#remote-debugging`), then `npx chrome-devtools-mcp@latest --autoConnect`.

**Icon States**: Gray/Black = not connected · Green = ready · Orange (...) = connecting · Red (!) = error

**When to use**: Existing logged-in sessions, browser extensions (especially password managers), or collaborating with AI on a page you're viewing.

**vs playwright-cli**: Use `playwright-cli` for headless automation (no MCP needed). Use Playwriter when you need existing browser state, extensions, or passwords.

<!-- AI-CONTEXT-END -->

## Installation

### 1. Install Extension

Install from [Chrome Web Store](https://chromewebstore.google.com/detail/playwriter-mcp/jfeammnjpkecdekppnclgkkffahnhfhe) — works in Chrome, Brave, and Edge. Pin to toolbar.

> **Edge**: Enable "Allow extensions from other stores" in `edge://extensions` first.

### 2. Connect to Tabs

Click the Playwriter extension icon on any tab you want to control. Icon turns green when connected.

### 3. Configure MCP

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

**OpenCode** (`~/.config/opencode/opencode.json`):

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

> Use full path to `npx` (e.g., `/opt/homebrew/bin/npx` on macOS with Homebrew) if the app runs with a restricted PATH.

**Enable per-agent** (OpenCode tools section):

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

Playwriter exposes a single `execute` tool that runs Playwright code:

```javascript
await page.goto('https://example.com')
await page.click('button.submit')
await page.fill('input[name="email"]', 'user@example.com')
await page.screenshot({ path: 'screenshot.png' })
const title = await page.textContent('h1')
await page.waitForSelector('.loaded')
```

### Multi-Tab Control

```javascript
const pages = context.pages()
const page1 = pages[0]
const newPage = await context.newPage()
await newPage.goto('https://example.com')
```

### Programmatic Usage

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

## Comparison with Other Tools

| Feature | Playwriter | BrowserMCP | Playwright MCP | Stagehand |
|---------|------------|------------|----------------|-----------|
| Tools | 1 (`execute`) | 17+ | 10+ | 4 primitives |
| Context bloat | Minimal | High | Medium | Low |
| API | Full Playwright | Limited | Full Playwright | Natural language |
| Browser | Your existing | New instance | New instance | New instance |
| Extensions | ✅ Reuse yours | ❌ | ❌ | ❌ |
| Sessions | ✅ Existing | ❌ | ❌ | ❌ |
| Detection bypass | ✅ Disconnect | ❌ | ❌ | ❌ |

**Use Playwriter when**: existing sessions, extensions (password managers, ad blockers), collaborating with AI past captchas, resource efficiency (no separate Chrome instance).

**Use other tools when**:
- **Stagehand** - Natural language automation, self-healing selectors
- **Playwright MCP** - Isolated automation, no extension needed
- **Crawl4AI** - Web scraping and content extraction

## Security

- **Local WebSocket Server** on `localhost:19988` — no CORS headers, only local processes can connect
- **User-controlled** — only tabs where you clicked the extension icon are accessible
- **Explicit consent** — Chrome shows automation banner on controlled tabs
- New tabs created by automation are controlled; unconnected tabs and remote access are not possible

## Common Patterns

### Login / Form Flow

```javascript
// Login
await page.goto('https://app.example.com/login')
await page.fill('input[name="email"]', 'user@example.com')
await page.fill('input[name="password"]', 'password')
await page.click('button[type="submit"]')
await page.waitForURL('**/dashboard')

// Form with select/checkbox
await page.fill('#name', 'John Doe')
await page.selectOption('#country', 'US')
await page.check('#terms')
await page.click('button[type="submit"]')
await page.waitForSelector('.success-message')
```

### Data Extraction

```javascript
const prices = await page.$$eval('.product-price',
  elements => elements.map(el => el.textContent)
)

const rows = await page.$$eval('table tr', rows =>
  rows.map(row => Array.from(row.querySelectorAll('td')).map(cell => cell.textContent))
)
```

### Screenshot and PDF

> **Screenshot size limit**: Do NOT use `fullPage: true` for screenshots intended for AI vision review. Full-page captures can exceed 8000px, which crashes the session (Anthropic hard-rejects images >8000px). Use viewport-sized screenshots for AI review. If full-page is needed for human review, resize before including in conversation: `magick full.png -resize "1568x1568>" full-resized.png`. See `prompts/build.txt` "Screenshot Size Limits".

```javascript
// Viewport-sized screenshot (safe for AI review)
await page.screenshot({ path: 'viewport.png' })

// Element screenshot (safe — element-scoped, not full page)
await page.locator('.chart').screenshot({ path: 'chart.png' })

// PDF export
await page.pdf({ path: 'page.pdf', format: 'A4' })
```

## Troubleshooting

**Extension not connecting**: Check it's installed and pinned → click icon on the tab (should turn green) → check for red error badge → reload tab.

**MCP not finding tabs**: Ensure extension is connected (green icon) → restart MCP client → verify WebSocket server on port 19988.

**Automation detection**: Disconnect extension (click icon → gray) → complete manual action (login, captcha) → reconnect (click icon → green) → continue automation.

## Resources

- **GitHub**: https://github.com/remorses/playwriter
- **Chrome Extension**: https://chromewebstore.google.com/detail/playwriter-mcp/jfeammnjpkecdekppnclgkkffahnhfhe
- **Playwright Docs**: https://playwright.dev/docs/api/class-page
