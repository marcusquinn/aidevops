---
description: Chromium stealth patches - remove automation detection signals from Playwright
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
---

# Stealth Patches (Chromium/Playwright)

Remove automation detection signals from Playwright/Chromium. Primary: `rebrowser-patches` (MIT). Lightweight alternative: `playwright-stealth`.

## Tool Selection

| Tool | Approach | Stealth | Best For |
|------|----------|---------|----------|
| **rebrowser-patches** | Patches Playwright source | High | Production, Cloudflare/DataDome |
| **playwright-stealth** | Runtime JS evasions | Medium | Quick Python scripts, basic evasion |
| **Manual args** | Chrome flags only | Low | Dev testing |

## rebrowser-patches

Fixes: `Runtime.enable` CDP leak, `navigator.webdriver`, CDP artifacts, headless indicators, `//# sourceURL=` leaks.

```bash
npx rebrowser-patches@latest patch        # Patch existing Playwright
npm install rebrowser-playwright          # Drop-in replacement (Node.js)
pip install rebrowser-playwright          # Drop-in replacement (Python)
npx rebrowser-patches@latest unpatch     # Restore original
```

**Node.js:**

```javascript
import { chromium } from 'rebrowser-playwright';  // or 'playwright' after patching
const browser = await chromium.launch({
  headless: true,
  args: ['--disable-blink-features=AutomationControlled'],
});
const context = await browser.newContext({
  viewport: { width: 1920, height: 1080 },
  userAgent: '<realistic UA string>',
});
```

**Python:**

```python
from rebrowser_playwright.sync_api import sync_playwright  # or playwright after patching
with sync_playwright() as p:
    browser = p.chromium.launch(headless=True, args=['--disable-blink-features=AutomationControlled'])
    context = browser.new_context(viewport={'width': 1920, 'height': 1080}, user_agent='<realistic UA string>')
```

## playwright-stealth (Python)

JS-level evasions: `navigator.webdriver`, plugins, languages, `chrome.runtime`, `window.chrome`, Permissions API, iframe detection, WebGL, `hardwareConcurrency`.

```python
from playwright.sync_api import sync_playwright
from playwright_stealth import stealth_sync  # pip install playwright-stealth

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page()
    stealth_sync(page)
    page.goto('https://bot.sannysoft.com')
```

## Manual Stealth Args

Minimal evasion via Chrome flags (no patching required):

```javascript
const browser = await chromium.launch({
  headless: true,
  args: [
    '--disable-blink-features=AutomationControlled',
    '--disable-infobars',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-component-extensions-with-background-pages',
  ],
  ignoreDefaultArgs: ['--enable-automation'],
});
```

## aidevops Integration

```bash
anti-detect-helper.sh setup --engine chromium
anti-detect-helper.sh launch --engine chromium --profile "my-profile"
```

```javascript
import { createStealthContext } from '~/.aidevops/agents/scripts/stealth-context.mjs';
const { browser, context, page } = await createStealthContext({
  headless: true,
  proxy: { server: 'socks5://127.0.0.1:1080' },  // optional
  profile: 'my-profile',                           // optional: saved state
});
```

## Detection Test Sites

| Site | URL |
|------|-----|
| BrowserScan | https://www.browserscan.net/bot-detection |
| SannyBot | https://bot.sannysoft.com |
| CreepJS | https://abrahamjuliot.github.io/creepjs/ |
| BrowserLeaks | https://browserleaks.com |
| Pixelscan | https://pixelscan.net |
| Incolumitas | https://bot.incolumitas.com |

## Limitations

- **rebrowser-patches**: Chromium only; re-patch after Playwright updates
- **playwright-stealth**: JS-level only; detectable by sophisticated anti-bots
- **Neither** handles fingerprint rotation, WebRTC/font spoofing
- **Full anti-detect**: Use Camoufox (`fingerprint-profiles.md`) -- C++ level fingerprint spoofing, Firefox-based, `pip upgrade` maintenance

| Aspect | rebrowser-patches | Camoufox |
|--------|------------------|----------|
| Detection bypass | Cloudflare, DataDome (basic) | DataDome, Imperva, Cloudflare (advanced) |
| Fingerprint spoofing | None | Full (C++ level) |
| Headless | Patched but detectable | Fully patched (appears headed) |
| Language | Node.js / Python | Python |
