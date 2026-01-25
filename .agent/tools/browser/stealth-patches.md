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

<!-- AI-CONTEXT-START -->

## Overview

Patches for Playwright/Chromium to remove automation detection signals. Uses `rebrowser-patches` (1.2k stars, MIT) as the primary solution, with `playwright-stealth` as a lightweight alternative.

## Tool Selection

| Tool | Approach | Stealth Level | Setup | Best For |
|------|----------|---------------|-------|----------|
| **rebrowser-patches** | Patches Playwright source | High | `npx rebrowser-patches patch` | Production, Cloudflare/DataDome bypass |
| **playwright-stealth** | Runtime JS evasions | Medium | `pip install playwright-stealth` | Quick Python scripts, basic evasion |
| **Manual args** | Chrome flags only | Low | Launch args | Minimal stealth, dev testing |

## rebrowser-patches

### What It Fixes

1. **Runtime.enable leak** - Anti-bots detect CDP `Runtime.enable` calls that Playwright makes
2. **navigator.webdriver** - Removes the `webdriver` flag
3. **CDP leak prevention** - Hides Chrome DevTools Protocol artifacts
4. **Headless detection** - Patches headless mode indicators
5. **sourceURL leak** - Removes `//# sourceURL=` from injected scripts

### Installation

```bash
# Patch existing Playwright installation (Node.js)
npx rebrowser-patches@latest patch

# Or use drop-in replacement package
npm install rebrowser-playwright
# Then: import { chromium } from 'rebrowser-playwright';

# Python drop-in replacement
pip install rebrowser-playwright
# Then: from rebrowser_playwright.sync_api import sync_playwright

# Unpatch (restore original)
npx rebrowser-patches@latest unpatch
```

### Usage (Node.js)

```javascript
// Option 1: Patched Playwright (after npx rebrowser-patches patch)
import { chromium } from 'playwright';

// Option 2: Drop-in replacement (no patching needed)
import { chromium } from 'rebrowser-playwright';

const browser = await chromium.launch({
  headless: true,
  args: [
    '--disable-blink-features=AutomationControlled',
  ]
});

const context = await browser.newContext({
  // Realistic viewport
  viewport: { width: 1920, height: 1080 },
  // Realistic user agent
  userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
});

const page = await context.newPage();
await page.goto('https://www.browserscan.net/bot-detection');
```

### Usage (Python)

```python
# Option 1: Drop-in replacement
from rebrowser_playwright.sync_api import sync_playwright

# Option 2: Standard playwright (after patching)
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(
        headless=True,
        args=['--disable-blink-features=AutomationControlled']
    )
    context = browser.new_context(
        viewport={'width': 1920, 'height': 1080},
        user_agent='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
    )
    page = context.new_page()
    page.goto('https://www.browserscan.net/bot-detection')
```

## playwright-stealth (Python)

Lightweight alternative for Python scripts. Applies JS-level evasions.

### Installation

```bash
pip install playwright-stealth
```

### Usage

```python
from playwright.sync_api import sync_playwright
from playwright_stealth import stealth_sync

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page()
    stealth_sync(page)  # Apply stealth evasions
    page.goto('https://bot.sannysoft.com')
```

### What It Patches (JS-level)

- `navigator.webdriver` → undefined
- `navigator.plugins` → realistic plugin list
- `navigator.languages` → matches Accept-Language
- `chrome.runtime` → realistic object
- `window.chrome` → present
- `Permissions.query` → realistic responses
- `iframe.contentWindow` → no blank detection
- `WebGL vendor/renderer` → realistic strings
- `navigator.hardwareConcurrency` → realistic value

## Manual Stealth Args (Minimal)

For basic stealth without additional packages:

```javascript
const browser = await chromium.launch({
  headless: true,
  args: [
    '--disable-blink-features=AutomationControlled',
    '--disable-infobars',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-component-extensions-with-background-pages',
    '--disable-default-apps',
    '--disable-extensions',
    '--disable-background-networking',
    '--disable-sync',
    '--metrics-recording-only',
    '--disable-hang-monitor',
    '--disable-prompt-on-repost',
  ],
  ignoreDefaultArgs: ['--enable-automation'],
});
```

## Integration with aidevops

### With anti-detect-helper.sh

```bash
# Setup rebrowser-patches
~/.aidevops/agents/scripts/anti-detect-helper.sh setup --engine chromium

# Launch with stealth (auto-applies patches)
~/.aidevops/agents/scripts/anti-detect-helper.sh launch --engine chromium --profile "my-profile"
```

### With Existing Playwright Scripts

```javascript
// Add to any existing Playwright script for stealth
import { createStealthContext } from '~/.aidevops/agents/scripts/stealth-context.mjs';

const { browser, context, page } = await createStealthContext({
  headless: true,
  proxy: { server: 'socks5://127.0.0.1:1080' },  // Optional
  profile: 'my-profile',  // Optional: load saved state
});
```

## Detection Test Sites

| Site | Tests | URL |
|------|-------|-----|
| **BrowserScan** | Bot detection, fingerprint | https://www.browserscan.net/bot-detection |
| **SannyBot** | WebDriver, CDP, headless | https://bot.sannysoft.com |
| **CreepJS** | Advanced fingerprinting | https://abrahamjuliot.github.io/creepjs/ |
| **BrowserLeaks** | WebRTC, Canvas, WebGL | https://browserleaks.com |
| **Pixelscan** | Fingerprint consistency | https://pixelscan.net |
| **Incolumitas** | Bot detection suite | https://bot.incolumitas.com |

## Limitations

- **rebrowser-patches**: Chromium only, needs re-patching after Playwright updates
- **playwright-stealth**: JS-level only, detectable by sophisticated anti-bots
- **Neither**: Handles fingerprint rotation, WebRTC spoofing, or font spoofing
- **For full anti-detect**: Use Camoufox (see `fingerprint-profiles.md`)

## Comparison: rebrowser-patches vs Camoufox

| Aspect | rebrowser-patches | Camoufox |
|--------|------------------|----------|
| **Detection bypass** | Cloudflare, DataDome (basic) | DataDome, Imperva, Cloudflare (advanced) |
| **Fingerprint spoofing** | None (add separately) | Full (C++ level) |
| **Speed** | Fast (Chromium) | Medium (Firefox) |
| **Headless** | Patched but detectable | Fully patched (appears headed) |
| **Maintenance** | Re-patch on updates | pip upgrade |
| **Language** | Node.js / Python | Python |
| **Best for** | Quick stealth on existing code | Full anti-detect profiles |

<!-- AI-CONTEXT-END -->
