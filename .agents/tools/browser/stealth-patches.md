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

Patches for Playwright/Chromium to remove automation detection signals. Uses `rebrowser-patches` (1.2k stars, MIT) as the primary solution, with `playwright-stealth` as a lightweight alternative.

## Tool Selection

| Tool | Approach | Stealth Level | Setup | Best For |
|------|----------|---------------|-------|----------|
| **rebrowser-patches** | Patches Playwright source | High | `npx rebrowser-patches patch` | Production, Cloudflare/DataDome bypass |
| **playwright-stealth** | Runtime JS evasions | Medium | `pip install playwright-stealth` | Quick Python scripts, basic evasion |
| **Manual args** | Chrome flags only | Low | Launch args | Minimal stealth, dev testing |

## rebrowser-patches

Fixes: Runtime.enable CDP leak, `navigator.webdriver` flag, CDP artifacts, headless indicators, `//# sourceURL=` leaks.

### Installation

```bash
npx rebrowser-patches@latest patch        # Patch existing Playwright (Node.js)
npm install rebrowser-playwright          # Drop-in replacement (Node.js)
pip install rebrowser-playwright          # Drop-in replacement (Python)
npx rebrowser-patches@latest unpatch     # Restore original
```

### Usage

**Node.js** — use patched playwright or drop-in:

```javascript
import { chromium } from 'rebrowser-playwright';  // or 'playwright' after patching

const browser = await chromium.launch({
  headless: true,
  args: ['--disable-blink-features=AutomationControlled'],
});
const context = await browser.newContext({
  viewport: { width: 1920, height: 1080 },
  userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
});
const page = await context.newPage();
await page.goto('https://www.browserscan.net/bot-detection');
```

**Python** — same options:

```python
from rebrowser_playwright.sync_api import sync_playwright  # or playwright after patching

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

JS-level evasions. Patches: `navigator.webdriver`, plugins, languages, `chrome.runtime`, `window.chrome`, Permissions API, iframe detection, WebGL strings, `hardwareConcurrency`.

```bash
pip install playwright-stealth
```

```python
from playwright.sync_api import sync_playwright
from playwright_stealth import stealth_sync

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page()
    stealth_sync(page)
    page.goto('https://bot.sannysoft.com')
```

## Manual Stealth Args (Minimal)

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

```bash
~/.aidevops/agents/scripts/anti-detect-helper.sh setup --engine chromium
~/.aidevops/agents/scripts/anti-detect-helper.sh launch --engine chromium --profile "my-profile"
```

```javascript
import { createStealthContext } from '~/.aidevops/agents/scripts/stealth-context.mjs';

const { browser, context, page } = await createStealthContext({
  headless: true,
  proxy: { server: 'socks5://127.0.0.1:1080' },  // Optional
  profile: 'my-profile',                           // Optional: load saved state
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

## Limitations & Comparison

- **rebrowser-patches**: Chromium only, needs re-patching after Playwright updates
- **playwright-stealth**: JS-level only, detectable by sophisticated anti-bots
- **Neither**: handles fingerprint rotation, WebRTC spoofing, or font spoofing
- **For full anti-detect**: Use Camoufox (see `fingerprint-profiles.md`)

| Aspect | rebrowser-patches | Camoufox |
|--------|------------------|----------|
| **Detection bypass** | Cloudflare, DataDome (basic) | DataDome, Imperva, Cloudflare (advanced) |
| **Fingerprint spoofing** | None (add separately) | Full (C++ level) |
| **Speed** | Fast (Chromium) | Medium (Firefox) |
| **Headless** | Patched but detectable | Fully patched (appears headed) |
| **Maintenance** | Re-patch on updates | pip upgrade |
| **Language** | Node.js / Python | Python |
| **Best for** | Quick stealth on existing code | Full anti-detect profiles |
