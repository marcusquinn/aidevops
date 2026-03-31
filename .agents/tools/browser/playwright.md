---
description: Cross-browser testing automation with Playwright MCP
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
  playwright_*: true
mcp:
  - playwright
---

# Playwright MCP

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Cross-browser testing and automation (fastest browser engine)
- **Install**: `npm install playwright && npx playwright install` (lib + browsers) | `npx @playwright/mcp@latest` (MCP server)
- **Browsers**: chromium, firefox, webkit + custom (Brave, Edge, Chrome via `executablePath`)
- **Headless**: Yes (default)
- **Performance**: Navigate 1.4s, form fill 0.9s, extraction 1.3s, reliability 0.64s avg
- **Parallel**: 5 contexts in 2.1s, 3 browsers in 1.9s, 10 pages in 1.8s
- **Subagents**: `playwright-emulation.md` (device/viewport), `playwright-cli.md` (CLI agent)

Underlying engine for dev-browser, agent-browser, and Stagehand. Supports proxy (HTTP/SOCKS5), session persistence (`storageState`/`userDataDir`), extensions via `launchPersistentContext`, network throttling, device emulation, ad blocking (Brave Shields or uBlock Origin), AI page understanding (`page.locator('body').ariaSnapshot()` ~0.01s, 50-200 tokens), Chrome DevTools MCP (`npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222`).

**When to use directly**: Maximum speed, full control, proxy support, parallel instances, extensions, custom browser engines, or when other wrappers add unnecessary overhead.

<!-- AI-CONTEXT-END -->

## Installation

```bash
./setup.sh --interactive           # Select: "Setup browser automation tools"
# Or manually:
npm install playwright             # Install library (needed for JS examples)
npx playwright install             # Install browsers
npx @playwright/mcp@latest         # Run MCP server
npx --no-install playwright --version  # Check if installed
```

MCP configuration (Claude Code, OpenCode, etc.):

```json
{
  "playwright": {
    "command": "npx",
    "args": ["@playwright/mcp@latest"]
  }
}
```

## Custom Browser Engines

Use `executablePath` to launch Brave, Edge, or Chrome instead of bundled Chromium.

### Executable Paths

| Browser | macOS | Linux | Windows |
|---------|-------|-------|---------|
| **Brave** | `/Applications/Brave Browser.app/Contents/MacOS/Brave Browser` | `/usr/bin/brave-browser` | `C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe` |
| **Edge** | `/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge` | `/usr/bin/microsoft-edge` | `C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe` |
| **Chrome** | `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome` | `/usr/bin/google-chrome` | `C:\Program Files\Google\Chrome\Application\chrome.exe` |
| **Chromium** (bundled) | Auto-detected by Playwright | Auto-detected | Auto-detected |

### Launch, Extensions, and Parallel Contexts

Extensions require `headless: false` on older Chromium; `--headless=new` supports them. Brave Shields may make uBlock Origin redundant.

```javascript
import { chromium } from 'playwright';

const executablePath = '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser';

// Simple launch
const browser = await chromium.launch({ executablePath, headless: true });

// Persistent context with extensions
const context = await chromium.launchPersistentContext('/tmp/brave-profile', {
  executablePath,
  headless: false,
  args: ['--load-extension=/path/to/ext', '--disable-extensions-except=/path/to/ext'],
});

// Parallel instances (isolated profiles)
const contexts = await Promise.all(
  [1, 2, 3].map(i =>
    chromium.launchPersistentContext(`/tmp/profile-${i}`, { executablePath, headless: false })
  )
);
```

## Testing Patterns

For device emulation (presets, viewport/HiDPI, geolocation, locale/timezone, permissions, color scheme, offline, responsive breakpoints), see `playwright-emulation.md`.

**Cross-browser**: Iterate `['chromium', 'firefox', 'webkit']` and call `playwright[browserName].launch()`.

**Mobile**: `browser.newContext({ ...devices['iPhone 12'] })`.

**Performance**: `page.evaluate(() => performance.getEntriesByType('navigation')[0])` for Core Web Vitals. Use CDP `Network.emulateNetworkConditions` for throttling.

**Visual regression**: `expect(page).toHaveScreenshot('name.png', { threshold: 0.2 })` across viewports `[1920, 1366, 375]`.

**Security**: Inject XSS payloads via `page.fill()`, assert no alert dialogs fire. Test auth flows with valid/invalid credentials and assert redirect targets.

**API interception**: `page.route('/api/**', route => route.fulfill({ json: mockData }))` or `page.waitForResponse(r => r.url().includes('/api/posts'))`.
