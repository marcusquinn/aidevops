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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Playwright MCP

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Cross-browser testing and automation (fastest browser engine) — engine for dev-browser, agent-browser, and Stagehand
- **Install**: `npm install playwright && npx playwright install` (lib + browsers) | `npx @playwright/mcp@latest` (MCP server)
- **Setup**: `./setup.sh --interactive` → "Setup browser automation tools"
- **MCP config**: `{ "playwright": { "command": "npx", "args": ["@playwright/mcp@latest"] } }`
- **Browsers**: chromium, firefox, webkit + custom (Brave, Edge, Chrome via `executablePath`)
- **Headless**: Yes (default) | **Proxy**: HTTP/SOCKS5 | **Session**: `storageState` / `userDataDir`
- **Extensions**: `launchPersistentContext` (requires `headless: false`; `--headless=new` on newer Chromium)
- **Ad blocking**: Brave Shields or uBlock Origin | **AI page understanding**: `page.locator('body').ariaSnapshot()` ~0.01s, 50-200 tokens
- **Performance**: Navigate 1.4s, form fill 0.9s, extraction 1.3s, reliability 0.64s avg
- **Parallel**: 5 contexts in 2.1s, 3 browsers in 1.9s, 10 pages in 1.8s
- **Chrome DevTools MCP**: `npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222`
- **Subagents**: `playwright-emulation.md` (device/viewport), `playwright-cli.md` (CLI agent)

<!-- AI-CONTEXT-END -->

## Custom Browser Engines

Use `executablePath` for Brave, Edge, or Chrome instead of bundled Chromium. Brave Shields may make uBlock Origin redundant.

| Browser | macOS | Linux | Windows |
|---------|-------|-------|---------|
| **Brave** | `/Applications/Brave Browser.app/Contents/MacOS/Brave Browser` | `/usr/bin/brave-browser` | `C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe` |
| **Edge** | `/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge` | `/usr/bin/microsoft-edge` | `C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe` |
| **Chrome** | `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome` | `/usr/bin/google-chrome` | `C:\Program Files\Google\Chrome\Application\chrome.exe` |
| **Chromium** (bundled) | Auto-detected by Playwright | Auto-detected | Auto-detected |

```javascript
import { chromium } from 'playwright';
const executablePath = '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser';

// Simple launch
const browser = await chromium.launch({ executablePath, headless: true });

// Persistent context with extensions (headless: false required)
const context = await chromium.launchPersistentContext('/tmp/brave-profile', {
  executablePath, headless: false,
  args: ['--load-extension=/path/to/ext', '--disable-extensions-except=/path/to/ext'],
});
```

## Testing Patterns

For device emulation (presets, viewport/HiDPI, geolocation, locale/timezone, permissions, color scheme, offline, responsive breakpoints), see `playwright-emulation.md`.

| Need | Pattern |
|------|---------|
| Cross-browser | Iterate `['chromium', 'firefox', 'webkit']` and call `playwright[browserName].launch()` |
| Mobile | `browser.newContext({ ...devices['iPhone 12'] })` |
| Performance | `page.evaluate(() => performance.getEntriesByType('navigation')[0])` for Core Web Vitals; use CDP `Network.emulateNetworkConditions` for throttling |
| Visual regression | `expect(page).toHaveScreenshot('name.png', { threshold: 0.2 })` across `[1920, 1366, 375]` |
| Security | Inject XSS payloads via `page.fill()`, assert no alert dialogs fire, and verify auth redirects for valid/invalid credentials |
| API interception | `page.route('/api/**', route => route.fulfill({ json: mockData }))` or `page.waitForResponse(r => r.url().includes('/api/posts'))` |
