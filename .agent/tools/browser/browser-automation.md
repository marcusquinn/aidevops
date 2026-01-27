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
            +-> Need to stay logged in across restarts? --> dev-browser (profile)
            +-> Need parallel test contexts? --> Playwright (isolated contexts)
            +-> Need visual debugging? --> dev-browser (headed) + DevTools MCP
            +-> CI/CD pipeline? --> playwright-cli, agent-browser, or Playwright
```

**AI page understanding** (how the AI "sees" the page):

```text
How should AI understand the page?
    |
    +-> Forms, navigation, clicking? --> ARIA snapshot (0.01s, 50-200 tokens)
    +-> Reading content? --> Text extraction (0.002s, raw text)
    +-> Finding interactive elements? --> Element scan (0.002s, tag/type/name)
    +-> Visual layout matters (charts, images)? --> Screenshot (0.05s, ~1K vision tokens)
    +-> All of the above? --> ARIA + element scan (skip vision unless stuck)
```

## Performance Benchmarks

Tested 2026-01-24, macOS ARM64 (Apple Silicon), headless, warm daemon. Median of 3 runs. Reproduce via `browser-benchmark.md`.

| Test | Playwright | dev-browser | agent-browser | Crawl4AI | Playwriter | Stagehand |
|------|-----------|-------------|---------------|----------|------------|-----------|
| **Navigate + Screenshot** | **1.43s** | 1.39s | 1.90s | 2.78s | 2.95s | 7.72s |
| **Form Fill** (4 fields) | **0.90s** | 1.34s | 1.37s | N/A | 2.24s | 2.58s |
| **Data Extraction** (5 items) | 1.33s | **1.08s** | 1.53s | 2.53s | 2.68s | 3.48s |
| **Multi-step** (click + nav) | **1.49s** | 1.49s | 3.06s | N/A | 4.37s | 4.48s |
| **Reliability** (avg, 3 runs) | **0.64s** | 1.07s | 0.66s | 0.52s | 1.96s | 1.74s |

**Key insight**: Playwright is the underlying engine for all tools except Crawl4AI. Screenshots are near-instant (~0.05s, 24-107KB) but rarely needed for AI automation - ARIA snapshots (~0.01s, 50-200 tokens) provide sufficient page understanding for form filling, clicking, and navigation. Use screenshots only for visual debugging or regression testing.

**Overhead from wrappers**:
- dev-browser: +0.1-0.4s (Bun TSX + WebSocket)
- agent-browser: +0.5-1.5s (Rust CLI + Node daemon), cold-start penalty on first run
- Stagehand: +1-5s (AI model calls for natural language)
- Playwriter: +1-2s (Chrome extension + CDP relay)

## Feature Matrix

| Feature | Playwright | playwright-cli | dev-browser | agent-browser | Crawl4AI | WaterCrawl | Playwriter | Stagehand |
|---------|-----------|----------------|-------------|---------------|----------|------------|------------|-----------|
| **Headless** | Yes | Yes (default) | Yes | Yes (default) | Yes | Cloud API | No (your browser) | Yes |
| **Session persistence** | storageState | Profile dir | Profile dir | state save/load | user_data_dir | API sessions | Your browser | Per-instance |
| **Cookie management** | Full API | Persistent | Persistent | CLI commands | Persistent | Via API | Your browser | Per-instance |
| **Proxy support** | Full | No | Via launch args | No | Full (ProxyConfig) | Datacenter+Residential | Your browser | Via args |
| **SOCKS5/VPN** | Yes | No | Possible | No | Yes | No | Your browser | Via args |
| **Browser extensions** | Yes (persistent ctx) | No | Yes (profile) | No | No | No | Yes (yours) | Possible |
| **Custom browser engine** | Yes (`executablePath`) | No (bundled) | Possible (launch args) | No (bundled) | Yes (`chrome_channel`) | No | Yes (your browser) | Yes (via Playwright) |
| **Multi-session** | Per-context | --session flag | Named pages | --session flag | Per-crawl | Per-request | Per-tab | Per-instance |
| **Form filling** | Full API | CLI fill/type | Full API | CLI fill/click | No | No | Full API | Natural language |
| **Screenshots** | Full API | CLI command | Full API | CLI command | Built-in | PDF/Screenshot | Full API | Via page |
| **Data extraction** | evaluate() | eval command | evaluate() | eval command | CSS/XPath/LLM | Markdown/JSON | evaluate() | extract() + schema |
| **Natural language** | No | No | No | No | LLM extraction | No | No | act/extract/observe |
| **Self-healing** | No | No | No | No | No | No | No | Yes |
| **AI-optimized output** | No | Snapshot + refs | ARIA snapshots | Snapshot + refs | Markdown/JSON | Markdown/JSON | No | Structured schemas |
| **Tracing** | Full API | Built-in CLI | Via Playwright | Via Playwright | No | No | Via CDP | Via Playwright |
| **Web search** | No | No | No | No | No | Yes | No | No |
| **Sitemap generation** | No | No | No | No | No | Yes | No | No |
| **Anti-detect** | rebrowser-patches | No | Via launch args | No | No | No | Your browser | Via Playwright |
| **Fingerprint rotation** | No (add Camoufox) | No | No | No | No | No | No | No |
| **Multi-profile** | storageState dirs | --session | Profile dir | --session | user_data_dir | N/A | No | No |
| **Setup required** | npm install | npm install -g | Server running | npm install | pip/Docker | API key | Extension click | npm + API key |
| **Interface** | JS/TS API | CLI | TS scripts | CLI | Python API | REST/SDK | JS API | JS/Python SDK |
| **Maintainer** | Microsoft | Microsoft | Community | Vercel | Community | WaterCrawl | Community | Browserbase |

## Quick Reference

| Tool | Best For | Speed | Setup |
|------|----------|-------|-------|
| **Playwright** | Raw speed, full control, proxy support | Fastest | `npm i playwright` |
| **playwright-cli** | AI agents, CLI automation, session isolation | Fast | `bun i -g @playwright/mcp` |
| **dev-browser** | Persistent sessions, dev testing, TypeScript | Fast | `dev-browser-helper.sh setup && start` |
| **agent-browser** | CLI/CI/CD, AI agents, parallel sessions | Fast (warm) | `agent-browser-helper.sh setup` |
| **Crawl4AI** | Web scraping, bulk extraction, structured data | Fast | `pip install crawl4ai` (venv) |
| **WaterCrawl** | Cloud API, web search, sitemap generation | Fast | `watercrawl-helper.sh setup` + API key |
| **Playwriter** | Existing browser, extensions, bypass detection | Medium | Chrome extension + `npx playwriter` |
| **Stagehand** | Unknown pages, natural language, self-healing | Slow | `stagehand-helper.sh setup` + API key |
| **Anti-detect** | Bot evasion, multi-account, fingerprint rotation | Medium | `anti-detect-helper.sh setup` |

## AI Page Understanding (Visual Verification)

For AI agents to understand page state, prefer lightweight methods over screenshots:

| Method | Speed | Token Cost | Best For |
|--------|-------|-----------|----------|
| **ARIA snapshot** | ~0.01s | ~50-200 tokens | Forms, navigation, interactive elements |
| **Text content** | ~0.002s | ~text length | Reading content, extraction |
| **Element scan** | ~0.002s | ~20/element | Form filling, clicking |
| **Screenshot** | ~0.05s | ~1K tokens (vision) | Visual debugging, regression, complex UIs |

**Recommendation**: Use ARIA snapshot + element scan for automation. Add screenshots only when debugging or when visual layout matters (charts, drag-and-drop, image-heavy pages).

```javascript
// Fast page understanding (no vision model needed)
const aria = await page.locator('body').ariaSnapshot();  // Structured tree
const text = await page.evaluate(() => document.body.innerText);  // Raw text
const elements = await page.evaluate(() => {
  return [...document.querySelectorAll('input, select, button, a')].map(el => ({
    tag: el.tagName.toLowerCase(), type: el.type, name: el.name || el.id,
    text: el.textContent?.trim().substring(0, 50),
  }));
});
```

## Parallel / Sandboxed Instances

| Tool | Method | Speed (tested) | Isolation |
|------|--------|----------------|-----------|
| **Playwright** | Multiple contexts (1 browser) | **5 contexts: 2.1s** | Cookies/storage isolated |
| **Playwright** | Multiple browsers (separate OS processes) | **3 browsers: 1.9s** | Full process isolation |
| **Playwright** | Multiple persistent contexts | **3 profiles: 1.6s** | Full profile + extension isolation |
| **Playwright** | 10 pages (same context) | **10 pages: 1.8s** | Shared session |
| **agent-browser** | `--session s1/s2/s3` | **3 sessions: 2.0s** | Per-session isolation |
| **Crawl4AI** | `arun_many(urls)` | **5 pages: 3.0s (1.7x vs sequential)** | Shared browser, parallel tabs |
| **Crawl4AI** | Multiple AsyncWebCrawler instances | **3 instances: 3.0s** | Fully isolated browsers |
| **dev-browser** | Named pages (`client.page("name")`) | Fast | Shared profile (not isolated) |
| **Playwriter** | Multiple connected tabs | N/A | Shared browser session |
| **Stagehand** | Multiple Stagehand instances | Slow (AI overhead per instance) | Full isolation |

## Extension Support (Password Managers, etc.)

| Tool | Load Extensions? | Interact with Extension UI? | Password Manager Autofill? |
|------|-----------------|---------------------------|---------------------------|
| **Playwright** (persistent) | Yes (`--load-extension`) | Yes (open popup via `chrome-extension://` URL) | Partial (needs unlock) |
| **dev-browser** | Yes (install in profile) | Yes (persistent profile) | Partial (needs unlock) |
| **Playwriter** | Yes (your browser) | Yes (already there) | **Yes** (already unlocked) |
| **agent-browser** | No | No | No |
| **Crawl4AI** | No | No | No |
| **Stagehand** | Possible (uses Playwright) | Untested | Untested |

**Password manager reality**: Extensions load fine, but password managers need to be **unlocked** before autofill works. Options:
1. **Playwriter** - uses your already-unlocked browser (easiest)
2. **Playwright persistent** - load extension + unlock via Bitwarden CLI (`bw unlock`)
3. **dev-browser** - install extension in profile, unlock once (persists)

## Custom Browser Engine Support (Brave, Edge, Chrome)

Tools that use Playwright's bundled Chromium can often be pointed at a different Chromium-based browser instead. This is useful for Brave's built-in Shields (ad/tracker blocking), Edge's enterprise features, or your existing Chrome profile.

| Tool | Brave | Edge | Chrome | How |
|------|-------|------|--------|-----|
| **Playwright** | Yes | Yes | Yes | `executablePath` in `launch()` or `launchPersistentContext()` |
| **Playwriter** | Yes | Yes | Yes | Install extension in whichever browser you use |
| **Stagehand** | Yes | Yes | Yes | `executablePath` in `browserOptions` (uses Playwright) |
| **Crawl4AI** | Yes | Yes | Yes | `chrome_channel` or `browser_path` in `BrowserConfig` |
| **dev-browser** | Possible | Possible | Possible | Modify launch args in server config |
| **playwright-cli** | No | No | No | Uses bundled Chromium only |
| **agent-browser** | No | No | No | Uses bundled Chromium only |
| **WaterCrawl** | No | No | No | Cloud API, no local browser |

**Browser executable paths** (macOS):

```text
Brave:  /Applications/Brave Browser.app/Contents/MacOS/Brave Browser
Edge:   /Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge
Chrome: /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
```

**Browser executable paths** (Linux):

```text
Brave:  /usr/bin/brave-browser
Edge:   /usr/bin/microsoft-edge
Chrome: /usr/bin/google-chrome
```

**Browser executable paths** (Windows):

```text
Brave:  C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe
Edge:   C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe
Chrome: C:\Program Files\Google\Chrome\Application\chrome.exe
```

**Why use a custom browser?**

| Browser | Built-in Advantage | Trade-off |
|---------|-------------------|-----------|
| **Brave** | Shields (ad/tracker blocking like uBlock Origin), built-in Tor, fingerprint randomization | Some sites detect Brave Shields |
| **Edge** | Enterprise SSO, Azure AD integration, IE mode for legacy apps | Heavier than Chromium |
| **Chrome** | Widest extension ecosystem, most tested | No built-in ad blocking |
| **Chromium** (bundled) | Cleanest automation baseline, no extra features | No ad blocking, no extensions by default |

**First-run preference**: When a tool supports custom browsers, the AI agent should ask the user on first use which browser they prefer. Store the preference in `~/.config/aidevops/browser-prefs.json`:

```json
{
  "preferred_browser": "brave",
  "browser_paths": {
    "brave": "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
    "edge": "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    "chrome": "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  },
  "extensions": {
    "ublock_origin": "/path/to/ublock-origin-unpacked"
  }
}
```

## Ad Blocker / Extension Loading (uBlock Origin)

Extensions like uBlock Origin reduce page noise, block trackers, and speed up page loads. This benefits both scraping (cleaner HTML) and automation (fewer pop-ups, consent banners).

| Tool | Load uBlock Origin? | How | Notes |
|------|---------------------|-----|-------|
| **Playwright** (persistent) | Yes | `--load-extension=/path/to/ublock` | Requires unpacked extension + persistent context |
| **dev-browser** | Yes | Install in profile (headed mode) | Persists across restarts |
| **Playwriter** | Yes | Already installed in your browser | Easiest - just use your browser |
| **Stagehand** | Possible | Via Playwright's `--load-extension` | Untested, uses Playwright underneath |
| **Crawl4AI** | No | N/A | No extension support |
| **agent-browser** | No | N/A | No extension support |
| **playwright-cli** | No | N/A | Uses bundled Chromium, no extension loading |
| **WaterCrawl** | No | N/A | Cloud API |

**Alternative to uBlock Origin**: Use **Brave browser** with Shields enabled - provides equivalent ad/tracker blocking without needing to load an extension. This works with any tool that supports custom browser engines (Playwright, Stagehand, Crawl4AI, Playwriter).

**Getting uBlock Origin unpacked** (for Playwright/Stagehand `--load-extension`):

```bash
# Clone the uBlock Origin repo
git clone https://github.com/nicedoc/nicedoc.io ~/.aidevops/extensions/ublock-origin
# Or download from Chrome Web Store and extract the .crx
# The unpacked extension directory is what --load-extension expects
```

**Playwright example with uBlock Origin**:

```javascript
import { chromium } from 'playwright';

const context = await chromium.launchPersistentContext(
  '/tmp/browser-profile',
  {
    headless: false,  // Extensions require headed mode in Chromium
    args: [
      '--load-extension=/path/to/ublock-origin-unpacked',
      '--disable-extensions-except=/path/to/ublock-origin-unpacked',
    ],
  }
);
const page = context.pages()[0] || await context.newPage();
await page.goto('https://example.com');
```

## Chrome DevTools MCP (Companion Tool)

Chrome DevTools MCP (`chrome-devtools-mcp`) is **not a browser** - it's a debugging/inspection layer that connects to any running Chrome/Chromium instance. Use it alongside any browser tool for:

- **Performance**: Lighthouse audits, Core Web Vitals (LCP, FID, CLS, TTFB)
- **Network**: Monitor/throttle requests, individual request throttling (Chrome 136+)
- **Debugging**: Console capture, CSS coverage, visual regression
- **SEO**: Meta extraction, structured data validation
- **Mobile**: Device emulation, touch simulation

```bash
# Connect to dev-browser
npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222

# Connect to any Chrome with remote debugging
npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222

# Launch its own headless Chrome
npx chrome-devtools-mcp@latest --headless

# With proxy
npx chrome-devtools-mcp@latest --proxyServer socks5://127.0.0.1:1080
```

**Pair with**: dev-browser (persistent profile + DevTools inspection), Playwright (speed + DevTools debugging), Playwriter (your browser + DevTools analysis).

**Ethical Rules**: Respect ToS, rate limit (2-5s delays), no spam, legitimate use only.
<!-- AI-CONTEXT-END -->

## Detailed Usage by Tool

### Playwright Direct (Fastest)

Best for: Maximum speed, full Playwright API, proxy support, fresh sessions.

```javascript
import { chromium } from 'playwright';

const browser = await chromium.launch({
  headless: true,
  proxy: { server: 'socks5://127.0.0.1:1080' }  // Optional
});
const page = await browser.newPage();
await page.goto('https://example.com');
await page.fill('input[name="email"]', 'user@example.com');
await page.screenshot({ path: '/tmp/screenshot.png' });

// Save state for reuse
await page.context().storageState({ path: 'state.json' });
await browser.close();

// Later: restore state
const context = await browser.newContext({ storageState: 'state.json' });
```

**Persistence**: Use `storageState` to save/load cookies and localStorage across sessions.

### Playwright CLI (AI Agents)

Best for: AI agent automation, CLI-first workflows, session isolation, Microsoft-maintained.

```bash
# Install (bun preferred for speed)
bun install -g @playwright/mcp@latest

# Basic workflow
playwright-cli open https://example.com
playwright-cli snapshot                    # Get accessibility tree with refs
playwright-cli click e2                    # Click by ref (note: no @ prefix)
playwright-cli fill e3 "user@example.com"  # Fill by ref
playwright-cli type "search query"         # Type into focused element
playwright-cli screenshot
playwright-cli close

# Parallel sessions
playwright-cli --session=s1 open https://site-a.com
playwright-cli --session=s2 open https://site-b.com
playwright-cli session-list

# Tracing for debugging
playwright-cli tracing-start
playwright-cli click e4
playwright-cli fill e7 "test"
playwright-cli tracing-stop
```

**Persistence**: Sessions preserve cookies/storage between calls. Use `--session=name` for isolation.

**vs agent-browser**: Simpler ref syntax (`e5` vs `@e5`), built-in tracing, Microsoft-maintained. agent-browser has Rust CLI for faster cold starts and more commands.

**Integrations**:
- **Chrome DevTools MCP**: Connect to playwright-cli's browser for Lighthouse, network monitoring
- **Anti-detect (rebrowser-patches)**: Apply patches to Playwright's Chromium, then use playwright-cli normally
- See `playwright-cli.md` for detailed integration examples

**Skill installation** (Claude Code):

```bash
/plugin marketplace add microsoft/playwright-cli
/plugin install playwright-cli
```

### Dev-Browser (Persistent Profile)

Best for: Development testing, staying logged in across sessions, TypeScript projects.

```bash
# Start server (profile persists across restarts)
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start

# Headless mode
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start-headless

# Execute scripts
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

**Persistence**: Profile directory (`~/.aidevops/dev-browser/skills/dev-browser/profiles/browser-data/`) retains cookies, localStorage, cache, and extension data across server restarts.

### Agent-Browser (CLI/CI/CD)

Best for: Shell scripts, CI/CD pipelines, AI agent integration, parallel sessions.

```bash
# Basic workflow
agent-browser open https://example.com
agent-browser snapshot -i              # Interactive elements with refs
agent-browser click @e2                # Click by ref
agent-browser fill @e3 "text"          # Fill by ref
agent-browser screenshot /tmp/page.png
agent-browser close

# Parallel sessions
agent-browser --session s1 open https://site-a.com
agent-browser --session s2 open https://site-b.com

# Save/load auth state
agent-browser state save ~/.aidevops/.agent-workspace/auth/site.json
agent-browser state load ~/.aidevops/.agent-workspace/auth/site.json
```

**Persistence**: Use `state save/load` for cookies and storage. Use `--session` for isolation.

**Note**: First run has a cold-start penalty (~3-5s) while the daemon starts. Subsequent commands are fast (~0.6s).

### Crawl4AI (Extraction)

Best for: Web scraping, structured data extraction, bulk crawling, LLM-ready output.

```python
# Activate venv first: source ~/.aidevops/crawl4ai-venv/bin/activate
import asyncio
from crawl4ai import AsyncWebCrawler, BrowserConfig, CrawlerRunConfig
from crawl4ai.extraction_strategy import JsonCssExtractionStrategy

async def extract():
    schema = {
        "name": "Products",
        "baseSelector": ".product",
        "fields": [
            {"name": "title", "selector": "h2", "type": "text"},
            {"name": "price", "selector": ".price", "type": "text"}
        ]
    }

    browser_config = BrowserConfig(
        headless=True,
        proxy_config={"server": "socks5://127.0.0.1:1080"},  # Optional
        use_persistent_context=True,       # Persist cookies
        user_data_dir="~/.aidevops/.agent-workspace/work/crawl4ai-profile"
    )
    run_config = CrawlerRunConfig(
        extraction_strategy=JsonCssExtractionStrategy(schema)
    )

    async with AsyncWebCrawler(config=browser_config) as crawler:
        result = await crawler.arun(url="https://example.com", config=run_config)
        print(result.extracted_content)  # JSON

asyncio.run(extract())
```

**Persistence**: Use `use_persistent_context=True` + `user_data_dir` for cookie/session persistence.

**Interactions**: Limited form/click support via `CrawlerRunConfig(js_code="...")` for custom JS or C4A-Script DSL (CLICK, TYPE, PRESS commands). For complex interactive flows, use Playwright or dev-browser instead.

**Note**: `use_persistent_context=True` can cause crashes with concurrent `arun_many` - use separate crawler instances for parallel persistent sessions.

### Playwriter (Your Browser)

Best for: Using your existing logged-in sessions, browser extensions, bypassing automation detection.

```bash
# 1. Install Chrome/Brave extension:
#    https://chromewebstore.google.com/detail/playwriter-mcp/jfeammnjpkecdekppnclgkkffahnhfhe

# 2. Click extension icon on tab to control (turns green)

# 3. Start MCP server (or use via MCP config)
npx playwriter@latest
```

```javascript
// Programmatic usage
import { chromium } from 'playwright-core';
const browser = await chromium.connectOverCDP("http://localhost:19988");
const context = browser.contexts()[0];
const page = context.pages()[0];  // Your existing tab

await page.fill('#search', 'query');
await page.screenshot({ path: '/tmp/screenshot.png' });
await browser.close();
```

**Persistence**: Inherits your browser's sessions, cookies, extensions, and proxy settings.

**Note**: Always headed (uses your visible browser). Best for tasks where you need your existing login state or want to collaborate with the AI in real-time.

### Stagehand (Natural Language)

Best for: Unknown page structures, self-healing automation, AI-powered extraction.

```javascript
import { Stagehand } from "@browserbasehq/stagehand";
import { z } from "zod";

const stagehand = new Stagehand({
  env: "LOCAL",
  headless: true,
  verbose: 0
});

await stagehand.init();
const page = stagehand.ctx.pages()[0];

// Navigate (standard Playwright)
await page.goto("https://example.com");

// Natural language actions (requires OpenAI/Anthropic API key)
await stagehand.act("click the login button");
await stagehand.act("fill in the email with user@example.com");

// Structured extraction with schema
const data = await stagehand.extract("get product details", z.object({
  name: z.string(),
  price: z.number()
}));

await stagehand.close();
```

**Persistence**: Per-instance only. No built-in session persistence.

**Note**: Natural language features require an OpenAI or Anthropic API key with quota. Without it, Stagehand works as a standard Playwright wrapper (use Playwright direct instead for better speed).

## Proxy Support

| Method | Works With | Setup |
|--------|-----------|-------|
| **Direct proxy config** | Playwright, Crawl4AI, Stagehand | Pass in launch/config options |
| **SOCKS5 VPN** (IVPN/Mullvad) | Playwright, Crawl4AI, Stagehand | `proxy: { server: 'socks5://...' }` |
| **System proxy** (macOS) | All tools | `networksetup -setsocksfirewallproxy "Wi-Fi" host port` |
| **Browser extension** (FoxyProxy) | Playwriter | Install in your browser |
| **Residential proxy** (sticky IP) | Playwright, Crawl4AI | Provider session ID for same IP |

**Persistent IP across restarts**: Use `storageState` (Playwright) or `user_data_dir` (Crawl4AI) combined with a sticky-session proxy provider.

## Session Persistence Summary

| Need | Tool | Method |
|------|------|--------|
| **Stay logged in across runs** | dev-browser | Automatic (profile directory) |
| **Save/restore auth state** | agent-browser | `state save/load` commands |
| **Reuse existing login** | Playwriter | Uses your browser directly |
| **Persistent cookies + proxy** | Playwright, Crawl4AI | `storageState`/`user_data_dir` + proxy config |
| **Fresh session each time** | Playwright, agent-browser | Default behaviour (no persistence) |

## Visual Debugging

**CRITICAL**: Before asking the user what they see, check yourself:

```bash
# agent-browser
agent-browser screenshot /tmp/debug.png
agent-browser errors
agent-browser console
agent-browser get url
agent-browser snapshot -i

# dev-browser
cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx <<'EOF'
import { connect } from "@/client.js";
const client = await connect("http://localhost:9222");
const page = await client.page("main");
await page.screenshot({ path: "/tmp/debug.png" });
console.log({ url: page.url(), title: await page.title() });
await client.disconnect();
EOF
```

**Self-diagnosis workflow**:
1. Action fails or unexpected result
2. Take screenshot
3. Check errors/console
4. Get snapshot/URL
5. Analyze and retry - only ask user if truly stuck

## Ethical Guidelines

- **Respect ToS**: Check site terms before automating
- **Rate limit**: 2-5 second delays between actions
- **No spam**: Don't automate mass messaging or fake engagement
- **Legitimate use**: Focus on genuine value, not manipulation
- **Privacy**: Don't scrape personal data without consent
