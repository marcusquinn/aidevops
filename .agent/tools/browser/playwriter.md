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
---

# Playwriter - Browser Extension MCP

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Browser automation via Chrome extension with full Playwright API
- **Install Extension**: [Chrome Web Store](https://chromewebstore.google.com/detail/playwriter-mcp/jfeammnjpkecdekppnclgkkffahnhfhe)
- **MCP**: `npx playwriter@latest`
- **Single Tool**: `execute` - runs Playwright code snippets

**Key Advantages**:
- **1 tool vs 17+** - Less context bloat than BrowserMCP/Antigravity
- **Full Playwright API** - LLMs already know it from training
- **Your existing browser** - Reuse extensions, sessions, cookies
- **Bypass detection** - Disconnect extension to bypass automation detection
- **Collaborate with AI** - Work alongside it in the same browser
- **Proxy via browser** - Uses whatever proxy your browser is configured with

**Performance**: Navigate 2.95s, form fill 2.24s, reliability 1.96s avg.
Always headed (uses your visible browser). Proxy support via browser settings or extensions (FoxyProxy etc.).

**Extensions**: Full access to all your installed extensions. Password managers already unlocked. This is the only tool where password manager autofill works without extra setup.

**Parallel**: Multiple connected tabs (click extension on each). Shared browser session (not isolated). For isolated parallel work, use Playwright direct.

**AI Page Understanding**: Standard Playwright API - use `page.locator('body').ariaSnapshot()` or element queries. Screenshots also work since it's your visible browser.

**Chrome DevTools MCP**: Your browser needs remote debugging enabled (`chrome://inspect/#remote-debugging`), then use `npx chrome-devtools-mcp@latest --autoConnect`.

**Icon States**:
- Gray/Black: Not connected
- Green: Connected and ready
- Orange (...): Connecting
- Red (!): Error

**When to use**: When you need your existing logged-in sessions, browser extensions (especially password managers), or want to collaborate with AI on a page you're viewing.

**vs playwright-cli**: Use `playwright-cli` for headless automation (no MCP needed, just CLI). Use Playwriter when you need your existing browser state, extensions, or passwords.

<!-- AI-CONTEXT-END -->

## Installation

### 1. Install Chrome Extension

Install from [Chrome Web Store](https://chromewebstore.google.com/detail/playwriter-mcp/jfeammnjpkecdekppnclgkkffahnhfhe) and pin to toolbar.

### 2. Connect to Tabs

Click the Playwriter extension icon on any tab you want to control. Icon turns green when connected.

### 3. Configure MCP

Add to your MCP client configuration:

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

> **Note**: Use full path to `npx` (e.g., `/opt/homebrew/bin/npx` on macOS with Homebrew) for reliability. The `-y` flag auto-confirms package installation.

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

**Enable per-agent** (OpenCode tools section):

```json
{
  "tools": {
    "playwriter_*": false
  },
  "agent": {
    "Build+": {
      "tools": {
        "playwriter_*": true
      }
    }
  }
}
```

> **Tip**: Disable globally with `"playwriter_*": false` in `tools`, then enable per-agent to reduce context token usage.

## Usage

### The `execute` Tool

Playwriter exposes a single `execute` tool that runs Playwright code:

```javascript
// Navigate
await page.goto('https://example.com')

// Click
await page.click('button.submit')

// Fill form
await page.fill('input[name="email"]', 'user@example.com')

// Screenshot
await page.screenshot({ path: 'screenshot.png' })

// Extract text
const title = await page.textContent('h1')

// Wait for element
await page.waitForSelector('.loaded')
```text

### Multi-Tab Control

```javascript
// Get all connected tabs
const pages = context.pages()

// Switch between tabs
const page1 = pages[0]
const page2 = pages[1]

// Create new tab
const newPage = await context.newPage()
await newPage.goto('https://example.com')
```text

### Programmatic Usage

Use with playwright-core directly:

```javascript
import { chromium } from 'playwright-core'
import { startPlayWriterCDPRelayServer, getCdpUrl } from 'playwriter'

const server = await startPlayWriterCDPRelayServer()
const browser = await chromium.connectOverCDP(getCdpUrl())

const context = browser.contexts()[0]
const page = context.pages()[0]

await page.goto('https://example.com')
await page.screenshot({ path: 'screenshot.png' })

await browser.close()
server.close()
```text

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
| Collaboration | ✅ Same browser | ❌ | ❌ | ❌ |

### When to Use Playwriter

- **Debugging existing sessions** - Start on a page with your logged-in state
- **Bypassing automation detection** - Disconnect extension temporarily
- **Using your extensions** - Ad blockers, password managers work
- **Collaborating with AI** - Help it past captchas in real-time
- **Resource efficiency** - No separate Chrome instance

### When to Use Other Tools

- **Stagehand** - Natural language automation, self-healing selectors
- **Playwright MCP** - Isolated automation, no extension needed
- **Crawl4AI** - Web scraping and content extraction

## Architecture

```text
+---------------------+     +-------------------+     +-----------------+
|   BROWSER           |     |   LOCALHOST       |     |   MCP CLIENT    |
|                     |     |                   |     |                 |
|  +---------------+  |     | WebSocket Server  |     |  +-----------+  |
|  |   Extension   |<--------->  :19988         |     |  | AI Agent  |  |
|  |  (bg script)  |  | WS  |                   |     |  | (Claude)  |  |
|  +-------+-------+  |     |  /extension       |     |  +-----------+  |
|          |          |     |       ^           |     |        |        |
|          | chrome   |     |       |           |     |        v        |
|          | .debug   |     |       v           |     |  +-----------+  |
|          v          |     |  /cdp/:id <--------------> |  execute  |  |
|  +---------------+  |     |                   |  WS |  |   tool    |  |
|  | Tab 1 (green) |  |     | Routes:           |     |  +-----------+  |
|  +---------------+  |     |  - CDP commands   |     |        |        |
|  +---------------+  |     |  - CDP events     |     |        v        |
|  | Tab 2 (green) |  |     |  - attach/detach  |     |  +-----------+  |
|  +---------------+  |     |    Target events  |     |  | Playwright|  |
|  +---------------+  |     +-------------------+     |  |    API    |  |
|  | Tab 3 (gray)  |  |                               |  +-----------+  |
|  +---------------+  |     Tab 3 not controlled      +-----------------+
+---------------------+
```text

## Security

### How It Works

1. **Local WebSocket Server** - Runs on `localhost:19988`
2. **Localhost-Only** - No CORS headers, only local processes can connect
3. **User-Controlled** - Only tabs where you clicked the extension icon
4. **Explicit Consent** - Chrome shows automation banner on controlled tabs

### What Can Be Controlled

- ✅ Tabs you explicitly connected (clicked extension icon)
- ✅ New tabs created by automation
- ❌ Other browser tabs
- ❌ Tabs you haven't connected

### What Cannot Happen

- ❌ Remote access (localhost-only)
- ❌ Passive monitoring of unconnected tabs
- ❌ Automatic spreading to new manual tabs

## Common Patterns

### Login Flow

```javascript
// Navigate to login
await page.goto('https://app.example.com/login')

// Fill credentials
await page.fill('input[name="email"]', 'user@example.com')
await page.fill('input[name="password"]', 'password')

// Click login
await page.click('button[type="submit"]')

// Wait for redirect
await page.waitForURL('**/dashboard')
```text

### Form Submission

```javascript
// Fill form fields
await page.fill('#name', 'John Doe')
await page.fill('#email', 'john@example.com')
await page.selectOption('#country', 'US')
await page.check('#terms')

// Submit
await page.click('button[type="submit"]')

// Wait for success
await page.waitForSelector('.success-message')
```text

### Data Extraction

```javascript
// Get all product prices
const prices = await page.$$eval('.product-price', 
  elements => elements.map(el => el.textContent)
)

// Get table data
const rows = await page.$$eval('table tr', rows => 
  rows.map(row => {
    const cells = row.querySelectorAll('td')
    return Array.from(cells).map(cell => cell.textContent)
  })
)
```text

### Screenshot and PDF

```javascript
// Full page screenshot
await page.screenshot({ path: 'full.png', fullPage: true })

// Element screenshot
await page.locator('.chart').screenshot({ path: 'chart.png' })

// PDF export
await page.pdf({ path: 'page.pdf', format: 'A4' })
```text

## Troubleshooting

### Extension Not Connecting

1. Check extension is installed and pinned
2. Click extension icon on the tab (should turn green)
3. Check for error badge (red !)
4. Reload the tab and try again

### MCP Not Finding Tabs

1. Ensure extension is connected (green icon)
2. Restart MCP client
3. Check WebSocket server is running on port 19988

### Automation Detection

1. Disconnect extension (click icon to turn gray)
2. Complete manual action (login, captcha)
3. Reconnect extension (click icon to turn green)
4. Continue automation

## Resources

- **GitHub**: https://github.com/remorses/playwriter
- **Chrome Extension**: https://chromewebstore.google.com/detail/playwriter-mcp/jfeammnjpkecdekppnclgkkffahnhfhe
- **Playwright Docs**: https://playwright.dev/docs/api/class-page
