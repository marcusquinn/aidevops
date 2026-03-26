---
description: Browser automation tool selection and usage guide
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

# Browser Automation - Tool Selection Guide

<!-- AI-CONTEXT-START -->

## Tool Selection: Decision Tree

Most tools run **headless by default**. Playwriter always headed (attaches to your browser).

**Preferences**: fastest tool that meets requirements → ARIA snapshots over screenshots (50-200 tokens vs ~1K) → headless over headed → CLI tools for AI agents.

```text
EXTRACT?
  Web search + crawl → WaterCrawl | Bulk CSS/XPath → Crawl4AI | One-off authenticated → curl-copy
  Need login first → Playwright/dev-browser then extract | Unknown structure → Crawl4AI LLM / Stagehand

AUTOMATE?
  Password manager/extensions:
    Already unlocked → Playwriter | Unlock once → dev-browser | Programmatic → Playwright + Bitwarden CLI
  Parallel sessions: speed → Playwright | CLI → playwright-cli/agent-browser --session
  Persistent login: with extensions → dev-browser | without → playwright-cli/storageState
  Proxy: direct → Playwright/Crawl4AI | via extension → Playwriter
  Self-healing/unknown structure → Stagehand (NL, slowest)
  AI agent CLI-first → playwright-cli (Microsoft) or agent-browser (Vercel, Rust)
  Just fast → Playwright direct (0.9s form fill)

DEBUG/INSPECT → Chrome DevTools MCP (dev-browser :9222 or any Playwright instance)

ANTI-DETECT?
  Quick stealth: Chromium → stealth-patches.md | Firefox → fingerprint-profiles.md
  Full stack → anti-detect-browser.md | Multi-account → browser-profiles.md | Proxy/geo → proxy-integration.md

TEST your app?
  QA pipeline → browser-qa-helper.sh | Mobile E2E → Maestro | Device emulation → playwright-emulation.md
  CI/CD → playwright-cli, agent-browser, or Playwright
```

## AI Page Understanding

ARIA snapshots are the default (50-200 tokens). Screenshots only for visual debugging (~1K tokens, vision model).

```javascript
const aria = await page.locator('body').ariaSnapshot();          // ~0.01s, 50-200 tokens
const text = await page.evaluate(() => document.body.innerText); // ~0.002s, text length
const elements = await page.evaluate(() =>
  [...document.querySelectorAll('input, select, button, a')].map(el => ({
    tag: el.tagName.toLowerCase(), type: el.type, name: el.name || el.id,
    text: el.textContent?.trim().substring(0, 50),
  }))
);
```

## Performance Benchmarks

Tested 2026-01-24, macOS ARM64, headless, warm daemon. Reproduce: `browser-benchmark.md`.

| Test | Playwright | dev-browser | agent-browser | Crawl4AI | Playwriter | Stagehand |
|------|-----------|-------------|---------------|----------|------------|-----------|
| Navigate + Screenshot | **1.43s** | 1.39s | 1.90s | 2.78s | 2.95s | 7.72s |
| Form Fill (4 fields) | **0.90s** | 1.34s | 1.37s | N/A | 2.24s | 2.58s |
| Data Extraction (5 items) | 1.33s | **1.08s** | 1.53s | 2.53s | 2.68s | 3.48s |
| Multi-step (click + nav) | **1.49s** | 1.49s | 3.06s | N/A | 4.37s | 4.48s |

**Overhead**: dev-browser +0.1-0.4s | agent-browser +0.5-1.5s (cold-start) | Stagehand +1-5s (AI) | Playwriter +1-2s (CDP)

## Feature Matrix

| Feature | Playwright | playwright-cli | dev-browser | agent-browser | Crawl4AI | Playwriter | Stagehand |
|---------|-----------|----------------|-------------|---------------|----------|------------|-----------|
| Headless | Yes | Yes | Yes | Yes | Yes | No | Yes |
| Session persistence | storageState | Profile dir | Profile dir | state save/load | user_data_dir | Your browser | Per-instance |
| Proxy | Full | No | Via args | No | Full | Your browser | Via args |
| Extensions | Yes | No | Yes | No | No | Yes | Possible |
| Self-healing / NL | No | No | No | No | LLM only | No | Yes |
| Setup | npm install | npm install -g | Server running | npm install | pip/Docker | Extension click | npm + API key |

## Parallel Sessions

| Tool | Method | Speed | Isolation |
|------|--------|-------|-----------|
| Playwright | Contexts / browsers | **1.6-2.1s** (3-10 instances) | Context to full process |
| agent-browser | `--session s1/s2/s3` | 3 sessions: 2.0s | Per-session |
| Crawl4AI | `arun_many(urls)` | 5 pages: 3.0s (1.7x) | Shared or isolated |
| dev-browser | `client.page("name")` | Fast | Shared profile |

## Extensions and Password Managers

**Unlock order**: Playwriter (already unlocked) > dev-browser (install in profile, unlock once) > Playwright persistent (load extension + `bw unlock`).

**Ad blocking**: Brave with Shields (no extension needed), or uBlock Origin in Playwright/dev-browser:

```javascript
const context = await chromium.launchPersistentContext('/tmp/browser-profile', {
  headless: false,
  args: ['--load-extension=/path/to/ublock-origin-unpacked',
         '--disable-extensions-except=/path/to/ublock-origin-unpacked'],
});
```

## Custom Browser Engines

All of Playwright, Playwriter, Crawl4AI, and Stagehand support Brave, Edge, Chrome, and Mullvad (Firefox). playwright-cli, agent-browser, and WaterCrawl use bundled Chromium only.

macOS paths: Brave `/Applications/Brave Browser.app/Contents/MacOS/Brave Browser` · Edge `/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge` · Chrome `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome` · Mullvad `/Applications/Mullvad Browser.app/Contents/MacOS/mullvadbrowser`

Store preference in `~/.config/aidevops/browser-prefs.json` (`preferred_browser`, `preferred_firefox`, `browser_paths`).

## Chrome DevTools MCP

```bash
npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222  # Connect to dev-browser
npx chrome-devtools-mcp@latest --headless                           # Own headless Chrome
```

**Pair with**: dev-browser (profile + inspection), Playwright (speed + debugging), Playwriter (your browser).

**Setup**: `watercrawl-helper.sh setup` | `anti-detect-helper.sh setup`

<!-- AI-CONTEXT-END -->

## Usage by Tool

### Playwright Direct

> **Screenshot limit**: Never `fullPage: true` for AI vision — full-page can exceed 8000px (Anthropic hard-rejects). Resize: `magick screenshot.png -resize "1568x1568>" out.png`. See `prompts/build.txt`.

```javascript
import { chromium } from 'playwright';
const browser = await chromium.launch({ headless: true, proxy: { server: 'socks5://127.0.0.1:1080' } });
const page = await browser.newPage();
await page.goto('https://example.com');
await page.fill('input[name="email"]', 'user@example.com');
await page.screenshot({ path: '/tmp/screenshot.png' });
await page.context().storageState({ path: 'state.json' }); // Save auth
await browser.close();
// Restore: browser.newContext({ storageState: 'state.json' })
```

### Playwright CLI

```bash
bun install -g @playwright/mcp@latest
playwright-cli open https://example.com
playwright-cli snapshot          # Accessibility tree with refs
playwright-cli click e2 && playwright-cli fill e3 "user@example.com"
playwright-cli screenshot && playwright-cli close
playwright-cli --session=s1 open https://site-a.com  # Parallel sessions
```

### Dev-Browser

```bash
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start
cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx <<'EOF'
import { connect, waitForPageLoad } from "@/client.js";
const client = await connect("http://localhost:9222");
const page = await client.page("main");
await page.goto("https://example.com");
await waitForPageLoad(page);
console.log({ title: await page.title() });
await client.disconnect();
EOF
```

Profile at `~/.aidevops/dev-browser/skills/dev-browser/profiles/browser-data/` retains cookies, localStorage, and extension data.

### Agent-Browser

Setup: `agent-browser-helper.sh setup`. Cold-start ~3-5s; subsequent ~0.6s.

```bash
agent-browser open https://example.com
agent-browser snapshot -i && agent-browser click @e2 && agent-browser fill @e3 "text"
agent-browser screenshot /tmp/page.png
agent-browser state save ~/.aidevops/.agent-workspace/auth/site.json
agent-browser --session s1 open https://site-a.com
agent-browser close
```

### Crawl4AI

```python
# source ~/.aidevops/crawl4ai-venv/bin/activate
import asyncio
from crawl4ai import AsyncWebCrawler, BrowserConfig, CrawlerRunConfig
from crawl4ai.extraction_strategy import JsonCssExtractionStrategy

schema = {"name": "Products", "baseSelector": ".product", "fields": [
    {"name": "title", "selector": "h2", "type": "text"},
    {"name": "price", "selector": ".price", "type": "text"}]}

async def extract():
    config = BrowserConfig(headless=True, use_persistent_context=True,
        user_data_dir="~/.aidevops/.agent-workspace/work/crawl4ai-profile")
    async with AsyncWebCrawler(config=config) as crawler:
        result = await crawler.arun(url="https://example.com",
            config=CrawlerRunConfig(extraction_strategy=JsonCssExtractionStrategy(schema)))
        print(result.extracted_content)

asyncio.run(extract())
```

> `use_persistent_context=True` crashes with concurrent `arun_many` — use separate crawler instances.

### Playwriter

```bash
# Install extension: https://chromewebstore.google.com/detail/playwriter-mcp/jfeammnjpkecdekppnclgkkffahnhfhe
# Click extension icon on tab to control (turns green), then:
npx playwriter@latest
```

```javascript
import { chromium } from 'playwright-core';
const browser = await chromium.connectOverCDP("http://localhost:19988");
const page = browser.contexts()[0].pages()[0];
await page.fill('#search', 'query');
await page.screenshot({ path: '/tmp/screenshot.png' });
await browser.close();
```

### Stagehand

Setup: `stagehand-helper.sh setup` + OpenAI or Anthropic API key.

```javascript
import { Stagehand } from "@browserbasehq/stagehand";
import { z } from "zod";
const stagehand = new Stagehand({ env: "LOCAL", headless: true, verbose: 0 });
await stagehand.init();
await stagehand.ctx.pages()[0].goto("https://example.com");
await stagehand.act("click the login button");
await stagehand.act("fill in the email with user@example.com");
const data = await stagehand.extract("get product details",
  z.object({ name: z.string(), price: z.number() }));
await stagehand.close();
```

## Session Persistence

| Need | Tool | Method |
|------|------|--------|
| Stay logged in | dev-browser | Automatic (profile directory) |
| Save/restore auth | agent-browser | `state save/load` |
| Reuse existing login | Playwriter | Uses your browser directly |
| Persistent cookies + proxy | Playwright, Crawl4AI | `storageState`/`user_data_dir` + proxy |
| Fresh session | Playwright, agent-browser | Default behaviour |

## Visual Debugging

```bash
agent-browser screenshot /tmp/debug.png && agent-browser errors && agent-browser snapshot -i
```

**NEVER use curl to verify frontend fixes** — server returns 200 even when React crashes client-side. Self-diagnosis: Action fails → screenshot → errors/console → snapshot/URL → analyze → retry → ask user only if truly stuck.

## Ethical Guidelines

Respect ToS, rate limit (2-5s delays), no spam, legitimate use only, no personal data without consent.
