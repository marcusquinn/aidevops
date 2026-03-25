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
    |       +-> One-off from authenticated page? --> curl-copy (DevTools → Copy as cURL)
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

## Quick Reference

| Tool | Best For | Speed | Sub-doc |
|------|----------|-------|---------|
| **Playwright** | Raw speed, full control, proxy support | Fastest | [playwright.md](playwright.md) |
| **playwright-cli** | AI agents, CLI automation, session isolation | Fast | [playwright-cli.md](playwright-cli.md) |
| **dev-browser** | Persistent sessions, dev testing, TypeScript | Fast | [dev-browser.md](dev-browser.md) |
| **agent-browser** | CLI/CI/CD, AI agents, parallel sessions | Fast (warm) | [agent-browser.md](agent-browser.md) |
| **Crawl4AI** | Web scraping, bulk extraction, structured data | Fast | [crawl4ai.md](crawl4ai.md) |
| **WaterCrawl** | Cloud API, web search, sitemap generation | Fast | [watercrawl.md](watercrawl.md) |
| **Playwriter** | Existing browser, extensions, bypass detection | Medium | [playwriter.md](playwriter.md) |
| **Stagehand** | Unknown pages, natural language, self-healing | Slow | [stagehand.md](stagehand.md) |
| **Anti-detect** | Bot evasion, multi-account, fingerprint rotation | Medium | [anti-detect-browser.md](anti-detect-browser.md) |

For detailed usage, code examples, and setup instructions, see each tool's sub-doc.

## Performance Benchmarks

Tested 2026-01-24, macOS ARM64 (Apple Silicon), headless, warm daemon. Median of 3 runs. Reproduce via `browser-benchmark.md`.

| Test | Playwright | dev-browser | agent-browser | Crawl4AI | Playwriter | Stagehand |
|------|-----------|-------------|---------------|----------|------------|-----------|
| **Navigate + Screenshot** | **1.43s** | 1.39s | 1.90s | 2.78s | 2.95s | 7.72s |
| **Form Fill** (4 fields) | **0.90s** | 1.34s | 1.37s | N/A | 2.24s | 2.58s |
| **Data Extraction** (5 items) | 1.33s | **1.08s** | 1.53s | 2.53s | 2.68s | 3.48s |
| **Multi-step** (click + nav) | **1.49s** | 1.49s | 3.06s | N/A | 4.37s | 4.48s |
| **Reliability** (avg, 3×nav+screenshot) | 0.64s | 1.07s | 0.66s | **0.52s** | 1.96s | 1.74s |

**Key insight**: Playwright is the underlying engine for all tools except Crawl4AI. ARIA snapshots (~0.01s, 50-200 tokens) beat screenshots (~0.05s, ~1K vision tokens) for AI automation — use screenshots only for visual debugging or regression testing.

**Wrapper overhead**: dev-browser +0.1-0.4s (Bun TSX + WebSocket) | agent-browser +0.5-1.5s (Rust CLI + Node daemon, cold-start penalty) | Stagehand +1-5s (AI model calls) | Playwriter +1-2s (Chrome extension + CDP relay)

## AI Page Understanding

| Method | Speed | Token Cost | Best For |
|--------|-------|-----------|----------|
| **ARIA snapshot** | ~0.01s | ~50-200 tokens | Forms, navigation, interactive elements |
| **Text content** | ~0.002s | ~text length | Reading content, extraction |
| **Element scan** | ~0.002s | ~20/element | Form filling, clicking |
| **Screenshot** | ~0.05s | ~1K tokens (vision) | Visual debugging, regression, complex UIs |

Use ARIA snapshot + element scan for automation. Add screenshots only when debugging or when visual layout matters.

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

## Extensions & Ad Blocking

| Tool | Load Extensions? | Extension UI? | Password Autofill? | uBlock Origin? |
|------|-----------------|---------------|---------------------|----------------|
| **Playwright** (persistent) | Yes (`--load-extension`) | Yes (popup via `chrome-extension://`) | Partial (needs unlock) | Yes |
| **dev-browser** | Yes (install in profile) | Yes (persistent profile) | Partial (needs unlock) | Yes |
| **Playwriter** | Yes (your browser) | Yes (already there) | **Yes** (already unlocked) | Yes (yours) |
| **Stagehand** | Possible (uses Playwright) | Untested | Untested | Possible |
| **agent-browser / Crawl4AI / playwright-cli / WaterCrawl** | No | No | No | No |

Password manager unlock paths: (1) **Playwriter** — uses your already-unlocked browser (easiest), (2) **Playwright persistent** — load extension + unlock via Bitwarden CLI, (3) **dev-browser** — install in profile, unlock once (persists).

**Alternative to uBlock**: Use **Brave browser** with Shields — equivalent ad/tracker blocking without loading an extension.

## Custom Browser Engine

| Tool | Brave | Edge | Chrome | Mullvad | How |
|------|-------|------|--------|---------|-----|
| **Playwright** | Yes | Yes | Yes | Yes (Firefox) | `executablePath` in `launch()` |
| **Playwriter** | Yes | Yes | Yes | Yes | Install extension in your browser |
| **Stagehand** | Yes | Yes | Yes | Yes (Firefox) | `executablePath` in `browserOptions` |
| **Crawl4AI** | Yes | Yes | Yes | Yes (Firefox) | `browser_path` in `BrowserConfig` |
| **Camoufox** | No | No | No | Partial | Both hardened Firefox; Camoufox preferred |
| **dev-browser** | Possible | Possible | Possible | No | Modify launch args in server config |
| **playwright-cli / agent-browser / WaterCrawl** | No | No | No | No | Bundled Chromium / cloud API |

**Executable paths:**

```text
macOS:
  Brave:   /Applications/Brave Browser.app/Contents/MacOS/Brave Browser
  Edge:    /Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge
  Chrome:  /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
  Mullvad: /Applications/Mullvad Browser.app/Contents/MacOS/mullvadbrowser

Linux:
  Brave: /usr/bin/brave-browser  |  Edge: /usr/bin/microsoft-edge
  Chrome: /usr/bin/google-chrome  |  Mullvad: /usr/bin/mullvad-browser

Windows:
  Brave:   C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe
  Edge:    C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe
  Chrome:  C:\Program Files\Google\Chrome\Application\chrome.exe
  Mullvad: C:\Program Files\Mullvad Browser\Browser\mullvadbrowser.exe
```

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

Mullvad Browser: Firefox ESR with Tor Browser privacy patches (without Tor network). Requires Playwright's Firefox driver. For programmatic fingerprint control, use Camoufox instead.

## Chrome DevTools MCP (Companion Tool)

Debugging/inspection layer that connects to any running Chrome/Chromium instance. Use alongside any browser tool.

```bash
npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222  # Connect to dev-browser
npx chrome-devtools-mcp@latest --headless                           # Launch own headless Chrome
npx chrome-devtools-mcp@latest --proxyServer socks5://127.0.0.1:1080
```

**Pair with**: dev-browser (persistent profile + inspection), Playwright (speed + debugging), Playwriter (your browser + analysis).

<!-- AI-CONTEXT-END -->

## Proxy Support

| Method | Works With | Setup |
|--------|-----------|-------|
| **Direct proxy config** | Playwright, Crawl4AI, Stagehand | Pass in launch/config options |
| **SOCKS5 VPN** (IVPN/Mullvad) | Playwright, Crawl4AI, Stagehand | `proxy: { server: 'socks5://...' }` |
| **System proxy** (macOS only) | All tools | `networksetup -setsocksfirewallproxy "Wi-Fi" host port` |
| **Browser extension** (FoxyProxy) | Playwriter | Install in your browser |
| **Residential proxy** (sticky IP) | Playwright, Crawl4AI | Provider session ID for same IP |

## Session Persistence

| Need | Tool | Method |
|------|------|--------|
| **Stay logged in across runs** | dev-browser | Automatic (profile directory) |
| **Save/restore auth state** | agent-browser | `state save/load` commands |
| **Reuse existing login** | Playwriter | Uses your browser directly |
| **Persistent cookies + proxy** | Playwright, Crawl4AI | `storageState`/`user_data_dir` + proxy config |
| **Fresh session each time** | Playwright, agent-browser | Default behaviour (no persistence) |

## Visual Debugging

**CRITICAL**: Before asking the user what they see, check yourself — take a screenshot, check errors/console, get snapshot/URL, analyze and retry. Only ask user if truly stuck.

**NEVER use curl/HTTP to verify frontend fixes**: Server returns 200 even when React crashes client-side. Always use browser screenshots to verify frontend fixes work.

> **Screenshot size limit**: Do NOT use `fullPage: true` for AI vision review. Full-page captures can exceed 8000px, crashing the session (Anthropic hard-rejects >8000px). Use viewport-sized screenshots. Resize full-page captures before including in conversation: `magick screenshot.png -resize "1568x1568>" screenshot-resized.png`. See `prompts/build.txt` "Screenshot Size Limits".

## Ethical Guidelines

- **Respect ToS**: Check site terms before automating
- **Rate limit**: 2-5 second delays between actions
- **No spam**: Don't automate mass messaging or fake engagement
- **Legitimate use**: Focus on genuine value, not manipulation
- **Privacy**: Don't scrape personal data without consent
