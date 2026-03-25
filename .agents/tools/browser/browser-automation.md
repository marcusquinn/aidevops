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

Most tools run **headless by default** (no visible window, no mouse/keyboard competition). Playwriter is always headed because it attaches to your existing browser session.

**Preferences** (apply in order):
1. Fastest tool that meets requirements
2. ARIA snapshots over screenshots for AI understanding (50-200 tokens vs ~1K)
3. Headless over headed (no mouse/window competition)
4. CLI tools (playwright-cli, agent-browser) for AI agents - simpler tool restriction
5. Playwright direct for TypeScript projects needing full API control

```text
What do you need?
    |
    +-> EXTRACT data (scraping, reading)?
    |       |
    |       +-> Need web search + crawl? --> WaterCrawl (cloud API with search)
    |       +-> Bulk pages / structured CSS/XPath? --> Crawl4AI (fastest extraction, parallel)
    |       +-> One-off from authenticated page? --> curl-copy (DevTools -> Copy as cURL)
    |       +-> Need to login/interact first? --> Playwright or dev-browser, then extract
    |       +-> Unknown structure, need AI to parse? --> Crawl4AI LLM mode or Stagehand extract()
    |       +-> Quick API without infrastructure? --> WaterCrawl (managed service)
    |
    +-> AUTOMATE (forms, clicks, multi-step)?
    |       |
    |       +-> Need password manager / extensions?
    |       |       |
    |       |       +-> Already unlocked in your browser? --> Playwriter (only option that works)
    |       |       +-> Can unlock manually once? --> dev-browser (persists in profile)
    |       |       +-> Need programmatic unlock? --> Playwright persistent + Bitwarden CLI
    |       |
    |       +-> Need parallel isolated sessions?
    |       |       |
    |       |       +-> Maximum speed? --> Playwright (5 contexts in 2.1s)
    |       |       +-> CLI/shell scripting? --> playwright-cli or agent-browser --session
    |       |       +-> Extraction parallel? --> Crawl4AI arun_many (1.7x speedup)
    |       |
    |       +-> Need persistent login across sessions?
    |       |       |
    |       |       +-> With extensions? --> dev-browser (profile persists)
    |       |       +-> Without extensions? --> playwright-cli (session profiles) or Playwright storageState
    |       |
    |       +-> Need proxy / VPN / residential IP?
    |       |       |
    |       |       +-> Direct config? --> Playwright or Crawl4AI (full proxy support)
    |       |       +-> Via browser extension (FoxyProxy)? --> Playwriter
    |       |       +-> System-wide? --> Any tool (inherits system proxy)
    |       |
    |       +-> Unknown page structure / self-healing?
    |       |       --> Stagehand (natural language, adapts to changes, slowest)
    |       |
    |       +-> AI agent (CLI-first, simple tool restriction)?
    |       |       --> playwright-cli (Microsoft official, `Bash(playwright-cli:*)`)
    |       |       --> agent-browser (Vercel, more CLI commands, Rust binary)
    |       |
    |       +-> None of the above (just fast automation)?
    |               --> Playwright direct (fastest, 0.9s form fill)
    |
    +-> DEBUG / INSPECT (performance, network, SEO)?
    |       --> Chrome DevTools MCP (companion, pairs with any browser tool)
    |       --> Best with: dev-browser (:9222) or Playwright
    |
    +-> ANTI-DETECT (avoid bot detection, multi-account)?
    |       |
    |       +-> Quick stealth (hide automation signals)?
    |       |       |
    |       |       +-> Chromium? --> stealth-patches.md (rebrowser-patches)
    |       |       +-> Firefox? --> fingerprint-profiles.md (Camoufox)
    |       |
    |       +-> Full anti-detect (fingerprint + proxy + profiles)?
    |       |       --> anti-detect-browser.md (decision tree for full stack)
    |       |
    |       +-> Multi-account management?
    |       |       --> browser-profiles.md (persistent/clean/warm profiles)
    |       |
    |       +-> Proxy per profile / geo-targeting?
    |               --> proxy-integration.md (residential, SOCKS5, rotation)
    |
    +-> TEST your own app (dev server)?
            |
            +-> Mission milestone QA (smoke + screenshots + links + a11y)?
            |       --> browser-qa-helper.sh (full pipeline)
            |       --> See tools/browser/browser-qa.md
            +-> Mobile E2E (Android/iOS/React Native/Flutter)?
            |       --> Maestro (YAML flows, no compilation, built-in flakiness tolerance)
            |       --> See tools/mobile/maestro.md
            +-> Need device emulation (mobile, tablet, responsive)?
            |       --> Playwright device presets (see playwright-emulation.md)
            |       --> Includes: viewport, touch, geolocation, locale, dark mode, offline
            +-> Need to stay logged in across restarts? --> dev-browser (profile)
            +-> Need parallel test contexts? --> Playwright (isolated contexts)
            +-> Need visual debugging? --> dev-browser (headed) + DevTools MCP
            +-> CI/CD pipeline? --> playwright-cli, agent-browser, or Playwright
```

## AI Page Understanding

ARIA snapshots are the default for automation. Screenshots only for visual debugging or regression.

| Method | Speed | Token Cost | Best For |
|--------|-------|-----------|----------|
| **ARIA snapshot** | ~0.01s | ~50-200 tokens | Forms, navigation, interactive elements |
| **Text content** | ~0.002s | ~text length | Reading content, extraction |
| **Element scan** | ~0.002s | ~20/element | Form filling, clicking |
| **Screenshot** | ~0.05s | ~1K tokens (vision) | Visual debugging, regression, complex UIs |

```javascript
// Fast page understanding (no vision model needed)
const aria = await page.locator('body').ariaSnapshot();
const text = await page.evaluate(() => document.body.innerText);
const elements = await page.evaluate(() => {
  return [...document.querySelectorAll('input, select, button, a')].map(el => ({
    tag: el.tagName.toLowerCase(), type: el.type, name: el.name || el.id,
    text: el.textContent?.trim().substring(0, 50),
  }));
});
```

## Performance Benchmarks

Tested 2026-01-24, macOS ARM64 (Apple Silicon), headless, warm daemon. Median of 3 runs. Reproduce via `browser-benchmark.md`.

| Test | Playwright | dev-browser | agent-browser | Crawl4AI | Playwriter | Stagehand |
|------|-----------|-------------|---------------|----------|------------|-----------|
| **Navigate + Screenshot** | **1.43s** | 1.39s | 1.90s | 2.78s | 2.95s | 7.72s |
| **Form Fill** (4 fields) | **0.90s** | 1.34s | 1.37s | N/A | 2.24s | 2.58s |
| **Data Extraction** (5 items) | 1.33s | **1.08s** | 1.53s | 2.53s | 2.68s | 3.48s |
| **Multi-step** (click + nav) | **1.49s** | 1.49s | 3.06s | N/A | 4.37s | 4.48s |
| **Reliability** (avg, 3x nav+screenshot) | 0.64s | 1.07s | 0.66s | **0.52s** | 1.96s | 1.74s |

**Key insight**: Playwright is the underlying engine for all tools except Crawl4AI. ARIA snapshots (~0.01s, 50-200 tokens) provide sufficient page understanding for most automation — screenshots are rarely needed.

**Wrapper overhead**: dev-browser +0.1-0.4s (Bun TSX + WebSocket) | agent-browser +0.5-1.5s (Rust CLI + Node daemon, cold-start penalty) | Stagehand +1-5s (AI model calls) | Playwriter +1-2s (Chrome extension + CDP relay)

## Feature Matrix

| Feature | Playwright | playwright-cli | dev-browser | agent-browser | Crawl4AI | WaterCrawl | Playwriter | Stagehand |
|---------|-----------|----------------|-------------|---------------|----------|------------|------------|-----------|
| **Headless** | Yes | Yes (default) | Yes | Yes (default) | Yes | Cloud API | No (your browser) | Yes |
| **Session persistence** | storageState | Profile dir | Profile dir | state save/load | user_data_dir | API sessions | Your browser | Per-instance |
| **Proxy support** | Full | No | Via launch args | No | Full (ProxyConfig) | Datacenter+Residential | Your browser | Via args |
| **Browser extensions** | Yes (persistent ctx) | No | Yes (profile) | No | No | No | Yes (yours) | Possible |
| **Custom browser engine** | Yes (`executablePath`) | No (bundled) | Possible | No (bundled) | Yes (`chrome_channel`) | No | Yes (your browser) | Yes (via Playwright) |
| **Form filling** | Full API | CLI fill/type | Full API | CLI fill/click | No | No | Full API | Natural language |
| **Data extraction** | evaluate() | eval command | evaluate() | eval command | CSS/XPath/LLM | Markdown/JSON | evaluate() | extract() + schema |
| **Self-healing / NL** | No | No | No | No | LLM extraction | No | No | Yes (act/extract/observe) |
| **AI-optimized output** | No | Snapshot + refs | ARIA snapshots | Snapshot + refs | Markdown/JSON | Markdown/JSON | No | Structured schemas |
| **Anti-detect** | rebrowser-patches | No | Via launch args | No | No | No | Your browser | Via Playwright |
| **Device emulation** | [Full](playwright-emulation.md) | resize command | Via Playwright | No | No | No | Your browser | Via Playwright |
| **Multi-profile** | storageState dirs | --session | Profile dir | --session | user_data_dir | N/A | No | No |
| **Setup** | npm install | npm install -g | Server running | npm install | pip/Docker | API key | Extension click | npm + API key |
| **Interface** | JS/TS API | CLI | TS scripts | CLI | Python API | REST/SDK | JS API | JS/Python SDK |
| **Maintainer** | Microsoft | Microsoft | Community | Vercel | Community | WaterCrawl | Community | Browserbase |

## Parallel / Sandboxed Instances

| Tool | Method | Speed (tested) | Isolation |
|------|--------|----------------|-----------|
| **Playwright** | Contexts / browsers / persistent / pages | **1.6-2.1s** (3-10 instances) | Context-level to full process |
| **agent-browser** | `--session s1/s2/s3` | **3 sessions: 2.0s** | Per-session isolation |
| **Crawl4AI** | `arun_many(urls)` or multiple instances | **5 pages: 3.0s** (1.7x vs sequential) | Shared browser or fully isolated |
| **dev-browser** | Named pages (`client.page("name")`) | Fast | Shared profile (not isolated) |
| **Playwriter** | Multiple connected tabs | N/A | Shared browser session |
| **Stagehand** | Multiple instances | Slow (AI overhead per instance) | Full isolation |

## Extensions and Ad Blocking

| Tool | Load Extensions? | Interact with Extension UI? | Password Manager Autofill? |
|------|-----------------|---------------------------|---------------------------|
| **Playwright** (persistent) | Yes (`--load-extension`) | Yes (open popup via `chrome-extension://` URL) | Partial (needs unlock) |
| **dev-browser** | Yes (install in profile) | Yes (persistent profile) | Partial (needs unlock) |
| **Playwriter** | Yes (your browser) | Yes (already there) | **Yes** (already unlocked) |
| **agent-browser / Crawl4AI / playwright-cli / WaterCrawl** | No | No | No |
| **Stagehand** | Possible (uses Playwright) | Untested | Untested |

**Password manager unlock order**: Playwriter (already unlocked) > dev-browser (install in profile, unlock once, persists) > Playwright persistent (load extension + unlock via Bitwarden CLI `bw unlock`).

**Ad blocking**: Use **Brave browser** with Shields (no extension needed), or load uBlock Origin in Playwright/dev-browser:

```javascript
// Playwright with uBlock Origin
const context = await chromium.launchPersistentContext('/tmp/browser-profile', {
  headless: false,
  args: [
    '--load-extension=/path/to/ublock-origin-unpacked',
    '--disable-extensions-except=/path/to/ublock-origin-unpacked',
  ],
});
```

## Custom Browser Engine Support

| Tool | Brave | Edge | Chrome | Mullvad | How |
|------|-------|------|--------|---------|-----|
| **Playwright** | Yes | Yes | Yes | Yes (Firefox) | `executablePath` in `launch()` |
| **Playwriter** | Yes | Yes | Yes | Yes | Install extension in your browser |
| **Stagehand** | Yes | Yes | Yes | Yes (Firefox) | `executablePath` in `browserOptions` |
| **Crawl4AI** | Yes | Yes | Yes | Yes (Firefox) | `browser_path` in `BrowserConfig` |
| **Camoufox** | No | No | No | Partial | Hardened Firefox; preferred over Mullvad for automation |
| **dev-browser** | Possible | Possible | Possible | No | Modify launch args |
| **Others** (playwright-cli, agent-browser, WaterCrawl) | No | No | No | No | Bundled Chromium / Cloud API |

**Browser executable paths** (macOS — Linux/Windows use standard install paths):

| Browser | macOS Path |
|---------|-----------|
| Brave | `/Applications/Brave Browser.app/Contents/MacOS/Brave Browser` |
| Edge | `/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge` |
| Chrome | `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome` |
| Mullvad | `/Applications/Mullvad Browser.app/Contents/MacOS/mullvadbrowser` |

| Browser | Advantage | Trade-off |
|---------|-----------|-----------|
| **Brave** | Shields (ad/tracker blocking), Tor, fingerprint randomization | Some sites detect Shields |
| **Edge** | Enterprise SSO, Azure AD, IE mode | Heavier than Chromium |
| **Chrome** | Widest extension ecosystem | No built-in ad blocking |
| **Chromium** (bundled) | Cleanest automation baseline | No extensions by default |
| **Mullvad** | Tor Browser-based anti-fingerprinting (Firefox ESR) | Some sites may break |

Mullvad requires Playwright's Firefox driver. For programmatic fingerprint control, use Camoufox instead.

Store preference in `~/.config/aidevops/browser-prefs.json`:

```json
{
  "preferred_browser": "brave",
  "preferred_firefox": "mullvad",
  "browser_paths": {
    "brave": "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
    "mullvad": "/Applications/Mullvad Browser.app/Contents/MacOS/mullvadbrowser"
  }
}
```

## Chrome DevTools MCP (Companion Tool)

Debugging/inspection layer that connects to any running Chrome/Chromium instance. Use alongside any browser tool for performance, network, debugging, SEO, and mobile emulation.

```bash
npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222  # Connect to dev-browser
npx chrome-devtools-mcp@latest --headless                           # Launch own headless Chrome
npx chrome-devtools-mcp@latest --proxyServer socks5://127.0.0.1:1080
```

**Pair with**: dev-browser (persistent profile + DevTools inspection), Playwright (speed + DevTools debugging), Playwriter (your browser + DevTools analysis).

**Other setup helpers**: `watercrawl-helper.sh setup` (WaterCrawl cloud API), `anti-detect-helper.sh setup` (anti-detect browser stack).

**Ethical rules**: Respect ToS, rate limit (2-5s delays), no spam, legitimate use only.

<!-- AI-CONTEXT-END -->

## Detailed Usage by Tool

### Playwright Direct (Fastest)

Best for: Maximum speed, full Playwright API, proxy support, fresh sessions.

> **Screenshot size limit**: Do NOT use `fullPage: true` for AI vision review. Full-page captures can exceed 8000px, crashing the session (Anthropic hard-rejects >8000px). Resize before including: `magick screenshot.png -resize "1568x1568>" screenshot-resized.png`. See `prompts/build.txt` "Screenshot Size Limits".

```javascript
import { chromium } from 'playwright';
const browser = await chromium.launch({ headless: true, proxy: { server: 'socks5://127.0.0.1:1080' } });
const page = await browser.newPage();
await page.goto('https://example.com');
await page.fill('input[name="email"]', 'user@example.com');
await page.screenshot({ path: '/tmp/screenshot.png' });  // viewport-sized (safe for AI)
await page.context().storageState({ path: 'state.json' }); // Save auth for reuse
await browser.close();
// Restore: browser.newContext({ storageState: 'state.json' })
```

### Playwright CLI (AI Agents)

Best for: AI agent automation, CLI-first workflows, session isolation, Microsoft-maintained.

```bash
bun install -g @playwright/mcp@latest

playwright-cli open https://example.com
playwright-cli snapshot                    # Get accessibility tree with refs
playwright-cli click e2                    # Click by ref
playwright-cli fill e3 "user@example.com"
playwright-cli screenshot
playwright-cli close

# Parallel sessions
playwright-cli --session=s1 open https://site-a.com
playwright-cli --session=s2 open https://site-b.com
```

**vs agent-browser**: Simpler ref syntax (`e5` vs `@e5`), built-in tracing, Microsoft-maintained. agent-browser has Rust CLI for faster cold starts and more commands.

### Dev-Browser (Persistent Profile)

Best for: Development testing, staying logged in across sessions, TypeScript projects.

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

Profile directory (`~/.aidevops/dev-browser/skills/dev-browser/profiles/browser-data/`) retains cookies, localStorage, cache, and extension data across restarts.

### Agent-Browser (CLI/CI/CD)

Best for: Shell scripts, CI/CD pipelines, AI agent integration, parallel sessions. Setup: `agent-browser-helper.sh setup`.

```bash
agent-browser open https://example.com
agent-browser snapshot -i              # Interactive elements with refs
agent-browser click @e2
agent-browser fill @e3 "text"
agent-browser screenshot /tmp/page.png
agent-browser state save ~/.aidevops/.agent-workspace/auth/site.json  # Persist auth
agent-browser --session s1 open https://site-a.com                    # Parallel sessions
agent-browser close
```

**Note**: Cold-start penalty (~3-5s) on first run while daemon starts. Subsequent commands ~0.6s.

### Crawl4AI (Extraction)

Best for: Web scraping, structured data extraction, bulk crawling, LLM-ready output.

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

**Note**: `use_persistent_context=True` crashes with concurrent `arun_many` — use separate crawler instances for parallel persistent sessions.

### Playwriter (Your Browser)

Best for: Using your existing logged-in sessions, browser extensions, bypassing automation detection.

```bash
# 1. Install Chrome/Brave extension:
#    https://chromewebstore.google.com/detail/playwriter-mcp/jfeammnjpkecdekppnclgkkffahnhfhe
# 2. Click extension icon on tab to control (turns green)
# 3. Start MCP server
npx playwriter@latest
```

```javascript
import { chromium } from 'playwright-core';
const browser = await chromium.connectOverCDP("http://localhost:19988");
const page = browser.contexts()[0].pages()[0]; // Your existing tab
await page.fill('#search', 'query');
await page.screenshot({ path: '/tmp/screenshot.png' });
await browser.close();
```

### Stagehand (Natural Language)

Best for: Unknown page structures, self-healing automation, AI-powered extraction. Setup: `stagehand-helper.sh setup` + API key.

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

**Note**: Natural language features require an OpenAI or Anthropic API key. Without it, Stagehand is a standard Playwright wrapper.

## Session Persistence

| Need | Tool | Method |
|------|------|--------|
| **Stay logged in across runs** | dev-browser | Automatic (profile directory) |
| **Save/restore auth state** | agent-browser | `state save/load` commands |
| **Reuse existing login** | Playwriter | Uses your browser directly |
| **Persistent cookies + proxy** | Playwright, Crawl4AI | `storageState`/`user_data_dir` + proxy config |
| **Fresh session each time** | Playwright, agent-browser | Default behaviour (no persistence) |

**Proxy**: Playwright, Crawl4AI, and Stagehand support direct proxy config (`proxy: { server: 'socks5://...' }`). Playwriter uses browser extensions (FoxyProxy). System proxy (`networksetup` on macOS) works with all tools. See decision tree for routing.

## Visual Debugging

**CRITICAL**: Before asking the user what they see, check yourself:

```bash
# agent-browser: screenshot, errors, console, get url, snapshot -i
agent-browser screenshot /tmp/debug.png && agent-browser errors && agent-browser snapshot -i

# dev-browser: use TSX script in ~/.aidevops/dev-browser/skills/dev-browser/
# page.screenshot(), page.url(), page.title()
```

**NEVER use curl/HTTP to verify frontend fixes** — server returns 200 even when React crashes client-side. Always use browser screenshots.

**Self-diagnosis**: Action fails -> screenshot -> errors/console -> snapshot/URL -> analyze and retry -> ask user only if truly stuck.

## Ethical Guidelines

- **Respect ToS**: Check site terms before automating
- **Rate limit**: 2-5 second delays between actions
- **No spam**: Don't automate mass messaging or fake engagement
- **Legitimate use**: Focus on genuine value, not manipulation
- **Privacy**: Don't scrape personal data without consent
