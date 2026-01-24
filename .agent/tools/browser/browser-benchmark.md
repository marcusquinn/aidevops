---
description: Run browser tool benchmarks to compare performance across all installed tools
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  task: true
---

# Browser Tool Benchmarking Agent

Run standardised benchmarks across all browser automation tools and update documentation with results.

## Quick Start

```bash
# Run all benchmarks
/browser-benchmark

# Run specific tool only
/browser-benchmark playwright

# Run specific test only
/browser-benchmark --test navigate

# Update docs with results
/browser-benchmark --update-docs
```

## Test Suite

Run each test 3 times per tool, report median. All tests use `https://the-internet.herokuapp.com` (stable test site).

### 1. Navigate + Screenshot

Open a page and take a screenshot.

| Tool | Method |
|------|--------|
| Playwright | `page.goto()` + `page.screenshot()` |
| dev-browser | TSX script via bun |
| agent-browser | `open` + `screenshot` CLI |
| Crawl4AI | `arun(url, screenshot=True)` |
| Playwriter | CDP connect + `page.screenshot()` |
| Stagehand | `page.goto()` + `page.screenshot()` |

**Target URL**: `https://the-internet.herokuapp.com/`

### 2. Form Fill (4 fields)

Fill a login form with username, password, and submit.

| Tool | Method |
|------|--------|
| Playwright | `page.fill()` x2 + `page.click()` |
| dev-browser | TSX script with fill/click |
| agent-browser | `fill` + `click` CLI commands |
| Crawl4AI | N/A (extraction only) |
| Playwriter | CDP `page.fill()` + `page.click()` |
| Stagehand | `stagehand.act("fill...")` |

**Target URL**: `https://the-internet.herokuapp.com/login`

### 3. Data Extraction (5 items)

Extract a list of items from a page.

| Tool | Method |
|------|--------|
| Playwright | `page.$$eval()` |
| dev-browser | TSX `page.$$eval()` |
| agent-browser | `eval` CLI command |
| Crawl4AI | `JsonCssExtractionStrategy` |
| Playwriter | CDP `page.$$eval()` |
| Stagehand | `stagehand.extract()` with schema |

**Target URL**: `https://the-internet.herokuapp.com/challenging_dom` (table rows)

### 4. Multi-step (click + navigate)

Click a link, wait for navigation, verify new page.

| Tool | Method |
|------|--------|
| Playwright | `page.click()` + `page.waitForURL()` |
| dev-browser | TSX click + waitForNavigation |
| agent-browser | `click` + `wait` + `get url` |
| Crawl4AI | N/A (no interaction) |
| Playwriter | CDP click + wait |
| Stagehand | `stagehand.act("click...")` |

**Target URL**: `https://the-internet.herokuapp.com/` (click "A/B Testing" link)

### 5. Reliability (3 consecutive runs)

Run navigate+screenshot 3 times consecutively, measure consistency.

Same as Test 1, repeated 3 times. Report average time.

## Benchmark Scripts

### Prerequisites Check

```bash
#!/bin/bash
# Check which tools are installed and ready

echo "=== Browser Tool Availability ==="

# Playwright
if command -v npx &>/dev/null && [ -d ~/.aidevops/playwright-bench/node_modules/playwright ]; then
  echo "[OK] Playwright direct"
else
  echo "[--] Playwright direct (run: mkdir -p ~/.aidevops/playwright-bench && cd ~/.aidevops/playwright-bench && npm init -y && npm i playwright)"
fi

# dev-browser
if [ -d ~/.aidevops/dev-browser/skills/dev-browser ]; then
  if curl -s http://localhost:9222/json/version &>/dev/null; then
    echo "[OK] dev-browser (server running)"
  else
    echo "[!!] dev-browser (installed, server not running - run: dev-browser-helper.sh start-headless)"
  fi
else
  echo "[--] dev-browser (run: dev-browser-helper.sh setup)"
fi

# agent-browser
if command -v agent-browser &>/dev/null; then
  echo "[OK] agent-browser"
else
  echo "[--] agent-browser (run: agent-browser-helper.sh setup)"
fi

# Crawl4AI
if [ -f ~/.aidevops/crawl4ai-venv/bin/python ]; then
  echo "[OK] Crawl4AI (venv)"
else
  echo "[--] Crawl4AI (run: python3 -m venv ~/.aidevops/crawl4ai-venv && source ~/.aidevops/crawl4ai-venv/bin/activate && pip install crawl4ai)"
fi

# Playwriter
if command -v npx &>/dev/null && npx playwriter --version &>/dev/null 2>&1; then
  echo "[!!] Playwriter (needs extension active on a tab - check localhost:19988)"
else
  echo "[--] Playwriter (run: npm i -g playwriter)"
fi

# Stagehand
if [ -d ~/.aidevops/stagehand-bench/node_modules/@browserbasehq/stagehand ]; then
  echo "[OK] Stagehand (needs OPENAI_API_KEY or ANTHROPIC_API_KEY)"
else
  echo "[--] Stagehand (run: mkdir -p ~/.aidevops/stagehand-bench && cd ~/.aidevops/stagehand-bench && npm init -y && npm i @browserbasehq/stagehand)"
fi
```

### Playwright Benchmark

```javascript
// ~/.aidevops/.agent-workspace/work/browser-bench/bench-playwright.mjs
import { chromium } from 'playwright';

const TESTS = {
  async navigate(page) {
    await page.goto('https://the-internet.herokuapp.com/');
    await page.screenshot({ path: '/tmp/bench-pw-nav.png' });
  },
  async formFill(page) {
    await page.goto('https://the-internet.herokuapp.com/login');
    await page.fill('#username', 'tomsmith');
    await page.fill('#password', 'SuperSecretPassword!');
    await page.click('button[type="submit"]');
    await page.waitForURL('**/secure');
  },
  async extract(page) {
    await page.goto('https://the-internet.herokuapp.com/challenging_dom');
    const rows = await page.$$eval('table tbody tr', trs =>
      trs.slice(0, 5).map(tr => tr.textContent.trim())
    );
    if (rows.length < 5) throw new Error('Expected 5+ rows');
  },
  async multiStep(page) {
    await page.goto('https://the-internet.herokuapp.com/');
    await page.click('a[href="/abtest"]');
    await page.waitForURL('**/abtest');
    const title = await page.title();
    if (!title) throw new Error('No title on target page');
  }
};

async function run() {
  const browser = await chromium.launch({ headless: true });
  const results = {};

  for (const [name, fn] of Object.entries(TESTS)) {
    const times = [];
    for (let i = 0; i < 3; i++) {
      const page = await browser.newPage();
      const start = performance.now();
      try {
        await fn(page);
        times.push(((performance.now() - start) / 1000).toFixed(2));
      } catch (e) {
        times.push(`ERR: ${e.message}`);
      }
      await page.close();
    }
    results[name] = times;
  }

  await browser.close();
  console.log(JSON.stringify(results, null, 2));
}

run();
```

### dev-browser Benchmark

```typescript
// Run via: cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx bench.ts
import { connect, waitForPageLoad } from "@/client.js";

const TESTS = {
  async navigate(page: any) {
    await page.goto('https://the-internet.herokuapp.com/');
    await waitForPageLoad(page);
    await page.screenshot({ path: '/tmp/bench-dev-nav.png' });
  },
  async formFill(page: any) {
    await page.goto('https://the-internet.herokuapp.com/login');
    await waitForPageLoad(page);
    await page.fill('#username', 'tomsmith');
    await page.fill('#password', 'SuperSecretPassword!');
    await page.click('button[type="submit"]');
    await page.waitForURL('**/secure');
  },
  async extract(page: any) {
    await page.goto('https://the-internet.herokuapp.com/challenging_dom');
    await waitForPageLoad(page);
    const rows = await page.$$eval('table tbody tr', (trs: any[]) =>
      trs.slice(0, 5).map(tr => tr.textContent.trim())
    );
    if (rows.length < 5) throw new Error('Expected 5+ rows');
  },
  async multiStep(page: any) {
    await page.goto('https://the-internet.herokuapp.com/');
    await waitForPageLoad(page);
    await page.click('a[href="/abtest"]');
    await page.waitForURL('**/abtest');
  }
};

async function run() {
  const client = await connect("http://localhost:9222");
  const results: Record<string, string[]> = {};

  for (const [name, fn] of Object.entries(TESTS)) {
    const times: string[] = [];
    for (let i = 0; i < 3; i++) {
      const page = await client.page("bench");
      const start = performance.now();
      try {
        await fn(page);
        times.push(((performance.now() - start) / 1000).toFixed(2));
      } catch (e: any) {
        times.push(`ERR: ${e.message}`);
      }
    }
    results[name] = times;
  }

  await client.disconnect();
  console.log(JSON.stringify(results, null, 2));
}

run();
```

### agent-browser Benchmark

```bash
#!/bin/bash
# bench-agent-browser.sh

TESTS=("navigate" "formFill" "extract" "multiStep")
declare -A RESULTS

bench_navigate() {
  local start end
  start=$(python3 -c 'import time; print(time.time())')
  agent-browser open "https://the-internet.herokuapp.com/" 2>/dev/null
  agent-browser screenshot /tmp/bench-ab-nav.png 2>/dev/null
  end=$(python3 -c 'import time; print(time.time())')
  echo "$(python3 -c "print(f'{$end - $start:.2f}')")"
  agent-browser close 2>/dev/null
}

bench_formFill() {
  local start end
  start=$(python3 -c 'import time; print(time.time())')
  agent-browser open "https://the-internet.herokuapp.com/login" 2>/dev/null
  agent-browser snapshot -i 2>/dev/null
  agent-browser fill '#username' 'tomsmith' 2>/dev/null
  agent-browser fill '#password' 'SuperSecretPassword!' 2>/dev/null
  agent-browser click 'button[type="submit"]' 2>/dev/null
  agent-browser wait url '**/secure' 2>/dev/null
  end=$(python3 -c 'import time; print(time.time())')
  echo "$(python3 -c "print(f'{$end - $start:.2f}')")"
  agent-browser close 2>/dev/null
}

bench_extract() {
  local start end
  start=$(python3 -c 'import time; print(time.time())')
  agent-browser open "https://the-internet.herokuapp.com/challenging_dom" 2>/dev/null
  agent-browser eval "JSON.stringify([...document.querySelectorAll('table tbody tr')].slice(0,5).map(r=>r.textContent.trim()))" 2>/dev/null
  end=$(python3 -c 'import time; print(time.time())')
  echo "$(python3 -c "print(f'{$end - $start:.2f}')")"
  agent-browser close 2>/dev/null
}

bench_multiStep() {
  local start end
  start=$(python3 -c 'import time; print(time.time())')
  agent-browser open "https://the-internet.herokuapp.com/" 2>/dev/null
  agent-browser click 'a[href="/abtest"]' 2>/dev/null
  agent-browser wait url '**/abtest' 2>/dev/null
  agent-browser get url 2>/dev/null
  end=$(python3 -c 'import time; print(time.time())')
  echo "$(python3 -c "print(f'{$end - $start:.2f}')")"
  agent-browser close 2>/dev/null
}

echo "=== agent-browser Benchmark ==="
for test in "${TESTS[@]}"; do
  echo -n "$test: "
  times=()
  for i in 1 2 3; do
    t=$(bench_"$test")
    times+=("$t")
    echo -n "${t}s "
  done
  echo ""
done
```

### Crawl4AI Benchmark

```python
# ~/.aidevops/.agent-workspace/work/browser-bench/bench-crawl4ai.py
# Run: source ~/.aidevops/crawl4ai-venv/bin/activate && python bench-crawl4ai.py
import asyncio
import time
import json
from crawl4ai import AsyncWebCrawler, BrowserConfig, CrawlerRunConfig
from crawl4ai.extraction_strategy import JsonCssExtractionStrategy

BROWSER_CONFIG = BrowserConfig(headless=True)

async def bench_navigate():
    config = CrawlerRunConfig(screenshot=True)
    async with AsyncWebCrawler(config=BROWSER_CONFIG) as crawler:
        start = time.time()
        result = await crawler.arun(url="https://the-internet.herokuapp.com/", config=config)
        elapsed = time.time() - start
        assert result.success, f"Failed: {result.error_message}"
        return f"{elapsed:.2f}"

async def bench_extract():
    schema = {
        "name": "TableRows",
        "baseSelector": "table tbody tr",
        "fields": [
            {"name": "text", "selector": "td:first-child", "type": "text"}
        ]
    }
    config = CrawlerRunConfig(
        extraction_strategy=JsonCssExtractionStrategy(schema)
    )
    async with AsyncWebCrawler(config=BROWSER_CONFIG) as crawler:
        start = time.time()
        result = await crawler.arun(
            url="https://the-internet.herokuapp.com/challenging_dom",
            config=config
        )
        elapsed = time.time() - start
        assert result.success
        data = json.loads(result.extracted_content)
        assert len(data) >= 5, f"Expected 5+ rows, got {len(data)}"
        return f"{elapsed:.2f}"

async def run():
    results = {}
    for name, fn in [("navigate", bench_navigate), ("extract", bench_extract)]:
        times = []
        for _ in range(3):
            t = await fn()
            times.append(t)
        results[name] = times

    print(json.dumps(results, indent=2))

asyncio.run(run())
```

### Stagehand Benchmark

```javascript
// ~/.aidevops/.agent-workspace/work/browser-bench/bench-stagehand.mjs
import { Stagehand } from "@browserbasehq/stagehand";
import { z } from "zod";

const TESTS = {
  async navigate(stagehand) {
    const page = stagehand.ctx.pages()[0];
    await page.goto('https://the-internet.herokuapp.com/');
    await page.screenshot({ path: '/tmp/bench-sh-nav.png' });
  },
  async formFill(stagehand) {
    const page = stagehand.ctx.pages()[0];
    await page.goto('https://the-internet.herokuapp.com/login');
    await stagehand.act("fill the username field with tomsmith");
    await stagehand.act("fill the password field with SuperSecretPassword!");
    await stagehand.act("click the Login button");
  },
  async extract(stagehand) {
    const page = stagehand.ctx.pages()[0];
    await page.goto('https://the-internet.herokuapp.com/challenging_dom');
    const data = await stagehand.extract("extract the first 5 rows from the table", z.object({
      rows: z.array(z.object({ text: z.string() }))
    }));
    if (data.rows.length < 5) throw new Error('Expected 5+ rows');
  },
  async multiStep(stagehand) {
    const page = stagehand.ctx.pages()[0];
    await page.goto('https://the-internet.herokuapp.com/');
    await stagehand.act("click the A/B Testing link");
    await page.waitForURL('**/abtest');
  }
};

async function run() {
  const results = {};

  for (const [name, fn] of Object.entries(TESTS)) {
    const times = [];
    for (let i = 0; i < 3; i++) {
      const stagehand = new Stagehand({ env: "LOCAL", headless: true, verbose: 0 });
      await stagehand.init();
      const start = performance.now();
      try {
        await fn(stagehand);
        times.push(((performance.now() - start) / 1000).toFixed(2));
      } catch (e) {
        times.push(`ERR: ${e.message}`);
      }
      await stagehand.close();
    }
    results[name] = times;
  }

  console.log(JSON.stringify(results, null, 2));
}

run();
```

## Running the Full Suite

```bash
# 1. Check prerequisites
bash bench-prereqs.sh

# 2. Run each tool's benchmark
cd ~/.aidevops/.agent-workspace/work/browser-bench/

# Playwright
node bench-playwright.mjs | tee results-playwright.json

# dev-browser (ensure server running)
cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx bench.ts | tee ~/results-dev-browser.json

# agent-browser
bash bench-agent-browser.sh | tee results-agent-browser.txt

# Crawl4AI
source ~/.aidevops/crawl4ai-venv/bin/activate && python bench-crawl4ai.py | tee results-crawl4ai.json

# Stagehand (needs API key)
OPENAI_API_KEY=... node bench-stagehand.mjs | tee results-stagehand.json

# 3. Compile results table
echo "Done. Compare results and update browser-automation.md benchmarks table."
```

## Updating Documentation

After running benchmarks, update the Performance Benchmarks table in `browser-automation.md`:

1. Take median of 3 runs for each test
2. Bold the fastest time per row
3. Update the "Key insight" section if relative performance changed
4. Note the date and environment (macOS version, chip, tool versions)

**Environment to record**:

```bash
echo "Date: $(date +%Y-%m-%d)"
echo "macOS: $(sw_vers -productVersion)"
echo "Chip: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Apple Silicon')"
echo "Node: $(node --version)"
echo "Bun: $(bun --version 2>/dev/null || echo 'N/A')"
echo "Python: $(python3 --version)"
```

## Interpreting Results

- **Cold start**: First run of agent-browser will be slower (daemon startup). Discard or note separately.
- **Network variance**: Times will vary by ~0.2-0.5s due to network. Use median of 3.
- **Stagehand API latency**: Depends on OpenAI/Anthropic API response time. Note which model used.
- **Crawl4AI N/A**: Cannot do form fill or multi-step (extraction only tool).
- **Playwriter**: Requires manual extension activation. May skip in automated runs.

## Parallel Instance Benchmarks

### Playwright Parallel Test

```javascript
// bench-parallel.mjs - Test parallel isolation methods
import { chromium } from 'playwright';

async function benchParallel() {
  const results = {};

  // Test 1: Multiple contexts (same browser, cookie-isolated)
  let start = performance.now();
  const browser = await chromium.launch({ headless: true });
  const contexts = await Promise.all(
    Array.from({ length: 5 }, () => browser.newContext())
  );
  await Promise.all(contexts.map(async ctx => {
    const page = await ctx.newPage();
    await page.goto('https://the-internet.herokuapp.com/login');
  }));
  results.multiContext = `${((performance.now() - start) / 1000).toFixed(2)}s (5 contexts)`;
  await browser.close();

  // Test 2: Multiple browsers (full OS-level isolation)
  start = performance.now();
  const browsers = await Promise.all(
    Array.from({ length: 3 }, () => chromium.launch({ headless: true }))
  );
  await Promise.all(browsers.map(async b => {
    const page = await b.newPage();
    await page.goto('https://the-internet.herokuapp.com/');
  }));
  results.multiBrowser = `${((performance.now() - start) / 1000).toFixed(2)}s (3 browsers)`;
  await Promise.all(browsers.map(b => b.close()));

  // Test 3: 10 parallel pages (shared context)
  start = performance.now();
  const b2 = await chromium.launch({ headless: true });
  const ctx = await b2.newContext();
  await Promise.all(Array.from({ length: 10 }, async () => {
    const p = await ctx.newPage();
    await p.goto('https://the-internet.herokuapp.com/');
  }));
  results.multiPage = `${((performance.now() - start) / 1000).toFixed(2)}s (10 pages)`;
  await b2.close();

  console.log(JSON.stringify(results, null, 2));
}

benchParallel();
```

### agent-browser Parallel Test

```bash
#!/bin/bash
# bench-parallel-ab.sh
start=$(python3 -c 'import time; print(time.time())')
agent-browser --session s1 open "https://the-internet.herokuapp.com/login" 2>/dev/null &
agent-browser --session s2 open "https://the-internet.herokuapp.com/checkboxes" 2>/dev/null &
agent-browser --session s3 open "https://the-internet.herokuapp.com/dropdown" 2>/dev/null &
wait
end=$(python3 -c 'import time; print(time.time())')
echo "3 parallel sessions: $(python3 -c "print(f'{$end - $start:.2f}')")s"

# Verify isolation
echo "s1: $(agent-browser --session s1 get url 2>/dev/null)"
echo "s2: $(agent-browser --session s2 get url 2>/dev/null)"
echo "s3: $(agent-browser --session s3 get url 2>/dev/null)"

agent-browser --session s1 close 2>/dev/null
agent-browser --session s2 close 2>/dev/null
agent-browser --session s3 close 2>/dev/null
```

### Crawl4AI Parallel Test

```python
# bench-parallel-crawl4ai.py
import asyncio, time
from crawl4ai import AsyncWebCrawler, BrowserConfig, CrawlerRunConfig

URLS = [
    "https://the-internet.herokuapp.com/login",
    "https://the-internet.herokuapp.com/checkboxes",
    "https://the-internet.herokuapp.com/dropdown",
    "https://the-internet.herokuapp.com/tables",
    "https://the-internet.herokuapp.com/frames",
]

async def run():
    browser_config = BrowserConfig(headless=True)
    run_config = CrawlerRunConfig(screenshot=True)

    # Sequential baseline
    start = time.time()
    async with AsyncWebCrawler(config=browser_config) as crawler:
        for url in URLS:
            await crawler.arun(url=url, config=run_config)
    seq = time.time() - start

    # Parallel with arun_many
    start = time.time()
    async with AsyncWebCrawler(config=browser_config) as crawler:
        await crawler.arun_many(urls=URLS, config=run_config)
    par = time.time() - start

    print(f"Sequential: {seq:.2f}s | Parallel: {par:.2f}s | Speedup: {seq/par:.1f}x")

asyncio.run(run())
```

## Extension Loading Benchmark

```javascript
// bench-extension.mjs - Test extension loading and interaction
import { chromium } from 'playwright';
import path from 'path';
import fs from 'fs';

const HOME = process.env.HOME;

// Find Bitwarden extension (adjust path for your setup)
const EXTENSIONS_DIR = path.join(HOME,
  'Library/Application Support/BraveSoftware/Brave-Browser/Default/Extensions');
const BITWARDEN_ID = 'nngceckbapebfimnlniiiahkandclblb';

async function benchExtension() {
  const extDir = path.join(EXTENSIONS_DIR, BITWARDEN_ID);
  if (!fs.existsSync(extDir)) {
    console.log('Bitwarden extension not found. Skipping.');
    return;
  }

  // Get latest version
  const versions = fs.readdirSync(extDir);
  const extPath = path.join(extDir, versions[versions.length - 1]);
  console.log(`Extension: ${extPath}\n`);

  const userDataDir = '/tmp/pw-ext-bench';
  try { fs.rmSync(userDataDir, { recursive: true }); } catch {}

  // Benchmark: Launch with extension
  const start = performance.now();
  const context = await chromium.launchPersistentContext(userDataDir, {
    headless: false,
    args: [
      '--no-first-run',
      `--disable-extensions-except=${extPath}`,
      `--load-extension=${extPath}`,
    ],
  });
  const launchTime = ((performance.now() - start) / 1000).toFixed(2);
  console.log(`Launch with extension: ${launchTime}s`);

  // Wait for service worker
  let sw = context.serviceWorkers()[0];
  if (!sw) sw = await context.waitForEvent('serviceworker', { timeout: 10000 }).catch(() => null);

  if (sw) {
    const extId = sw.url().split('/')[2];
    console.log(`Extension ID: ${extId}`);

    // Open popup
    const popup = await context.newPage();
    await popup.goto(`chrome-extension://${extId}/popup/index.html`);
    await popup.waitForLoadState('domcontentloaded');
    await popup.waitForTimeout(2000);

    // Screenshot popup
    await popup.screenshot({ path: '/tmp/bench-ext-popup.png' });
    const buttons = await popup.$$('button');
    const inputs = await popup.$$('input');
    console.log(`Popup: ${buttons.length} buttons, ${inputs.length} inputs`);
    await popup.close();
  }

  // Test content script injection on login page
  const page = context.pages()[0] || await context.newPage();
  await page.goto('https://github.com/login');
  await page.waitForLoadState('networkidle');
  await page.waitForTimeout(3000);
  await page.screenshot({ path: '/tmp/bench-ext-login.png' });

  await context.close();
  console.log('Screenshots: /tmp/bench-ext-popup.png, /tmp/bench-ext-login.png');
}

benchExtension().catch(console.error);
```

## Visual Verification Benchmark

Test the AI's ability to understand page content via screenshots.

```javascript
// bench-visual.mjs - Screenshot + AI analysis workflow timing
import { chromium } from 'playwright';
import fs from 'fs';

const PAGES = [
  { url: 'https://the-internet.herokuapp.com/login', expect: 'login form' },
  { url: 'https://the-internet.herokuapp.com/tables', expect: 'data table' },
  { url: 'https://the-internet.herokuapp.com/checkboxes', expect: 'checkboxes' },
];

async function benchVisual() {
  const browser = await chromium.launch({ headless: true });
  const results = [];

  for (const { url, expect: expected } of PAGES) {
    const page = await browser.newPage();
    const start = performance.now();

    // Navigate
    await page.goto(url);
    await page.waitForLoadState('networkidle');

    // Take screenshot
    const screenshotPath = `/tmp/bench-visual-${Date.now()}.png`;
    await page.screenshot({ path: screenshotPath, fullPage: true });

    // Get ARIA snapshot (text representation for AI)
    const ariaSnapshot = await page.accessibility.snapshot();

    // Get page text content
    const textContent = await page.evaluate(() => document.body.innerText.substring(0, 500));

    const elapsed = ((performance.now() - start) / 1000).toFixed(2);

    results.push({
      url,
      expected,
      elapsed: `${elapsed}s`,
      screenshotSize: `${(fs.statSync(screenshotPath).size / 1024).toFixed(0)}KB`,
      ariaNodes: ariaSnapshot?.children?.length || 0,
      textPreview: textContent.substring(0, 100),
    });

    await page.close();
  }

  await browser.close();
  console.log(JSON.stringify(results, null, 2));
}

benchVisual();
```

**Visual verification workflow** (for AI agents):
1. Navigate to page
2. Take screenshot (PNG, full page)
3. Get ARIA accessibility snapshot (structured text)
4. AI analyses screenshot + ARIA to understand page state
5. Decide next action based on visual understanding

**Key metrics to capture**:
- Screenshot file size (affects token cost if sent to vision API)
- ARIA snapshot node count (structured alternative to vision)
- Time from navigate to screenshot-ready
- Whether ARIA snapshot alone is sufficient vs needing vision

## Chrome DevTools MCP Benchmark

Test DevTools as a companion to other browser tools.

```bash
#!/bin/bash
# bench-devtools.sh - Test DevTools MCP capabilities

echo "=== Chrome DevTools MCP Benchmark ==="

# Ensure dev-browser is running (provides the Chrome instance)
bash ~/.aidevops/agents/scripts/dev-browser-helper.sh status >/dev/null 2>&1 || \
  bash ~/.aidevops/agents/scripts/dev-browser-helper.sh start-headless

# Test: Performance audit via DevTools connected to dev-browser
echo "1. Lighthouse audit (via DevTools + dev-browser):"
start=$(python3 -c 'import time; print(time.time())')
# DevTools MCP would be called via MCP tool here
# npx chrome-devtools-mcp@latest --browserUrl http://127.0.0.1:9222
end=$(python3 -c 'import time; print(time.time())')
echo "   (Run via MCP tool - measures Lighthouse audit time)"

echo ""
echo "2. Network monitoring:"
echo "   (DevTools captures all network requests during automation)"

echo ""
echo "3. Best pairing for your use cases:"
echo "   - Dev testing: dev-browser + DevTools (persistent + inspection)"
echo "   - AI automation: Playwright + DevTools (speed + debugging)"
echo "   - Extension testing: Playwriter + DevTools (your browser + profiling)"
```

## Adding New Tools

When a new browser tool is added to the framework:

1. Add a benchmark script following the pattern above
2. Add the tool to the prerequisites check
3. Run the full suite including the new tool
4. Update `browser-automation.md` tables (Performance, Feature Matrix, Parallel, Extensions)
5. Update this file's test methods table
6. Test parallel capabilities and extension support
7. Test visual verification (screenshot quality, ARIA snapshot depth)
