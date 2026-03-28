# Browser Benchmark Scripts

Reference scripts for `browser-benchmark.md`. Each follows the same pattern: navigate, formFill, extract, multiStep — 3 runs each, median reported.

## Playwright

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
    const rows = await page.$$eval('table tbody tr', trs => trs.slice(0, 5).map(tr => tr.textContent.trim()));
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
      try { await fn(page); times.push(((performance.now() - start) / 1000).toFixed(2)); }
      catch (e) { times.push(`ERR: ${e.message}`); }
      await page.close();
    }
    results[name] = times;
  }
  await browser.close();
  console.log(JSON.stringify(results, null, 2));
}
run();
```

## dev-browser

```typescript
// Run via: cd ~/.aidevops/dev-browser/skills/dev-browser && bun x tsx bench.ts
import { connect, waitForPageLoad } from "@/client.js";
import type { Page } from "playwright";

const TESTS = {
  async navigate(page: Page) {
    await page.goto('https://the-internet.herokuapp.com/');
    await waitForPageLoad(page);
    await page.screenshot({ path: '/tmp/bench-dev-nav.png' });
  },
  async formFill(page: Page) {
    await page.goto('https://the-internet.herokuapp.com/login');
    await waitForPageLoad(page);
    await page.fill('#username', 'tomsmith');
    await page.fill('#password', 'SuperSecretPassword!');
    await page.click('button[type="submit"]');
    await page.waitForURL('**/secure');
  },
  async extract(page: Page) {
    await page.goto('https://the-internet.herokuapp.com/challenging_dom');
    await waitForPageLoad(page);
    const rows = await page.$$eval('table tbody tr', (trs: Element[]) =>
      trs.slice(0, 5).map(tr => tr.textContent?.trim() ?? ''));
    if (rows.length < 5) throw new Error('Expected 5+ rows');
  },
  async multiStep(page: Page) {
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
      try { await fn(page); times.push(((performance.now() - start) / 1000).toFixed(2)); }
      catch (e: any) { times.push(`ERR: ${e.message}`); }
    }
    results[name] = times;
  }
  await client.disconnect();
  console.log(JSON.stringify(results, null, 2));
}
run();
```

## agent-browser

```bash
#!/bin/bash
# bench-agent-browser.sh
set -euo pipefail

bench_navigate() {
  local start end
  start=$(python3 -c 'import time; print(time.time())')
  agent-browser open "https://the-internet.herokuapp.com/"
  agent-browser screenshot /tmp/bench-ab-nav.png
  end=$(python3 -c 'import time; print(time.time())')
  python3 -c "print(f'{$end - $start:.2f}')"
  agent-browser close
  return 0
}

bench_formFill() {
  local start end
  start=$(python3 -c 'import time; print(time.time())')
  agent-browser open "https://the-internet.herokuapp.com/login"
  agent-browser snapshot -i
  agent-browser fill '@username' 'tomsmith'
  agent-browser fill '@password' 'SuperSecretPassword!'
  agent-browser click '@submit'
  agent-browser wait --url '**/secure'
  end=$(python3 -c 'import time; print(time.time())')
  python3 -c "print(f'{$end - $start:.2f}')"
  agent-browser close
  return 0
}

bench_extract() {
  local start end
  start=$(python3 -c 'import time; print(time.time())')
  agent-browser open "https://the-internet.herokuapp.com/challenging_dom"
  agent-browser eval "JSON.stringify([...document.querySelectorAll('table tbody tr')].slice(0,5).map(r=>r.textContent.trim()))"
  end=$(python3 -c 'import time; print(time.time())')
  python3 -c "print(f'{$end - $start:.2f}')"
  agent-browser close
  return 0
}

bench_multiStep() {
  local start end
  start=$(python3 -c 'import time; print(time.time())')
  agent-browser open "https://the-internet.herokuapp.com/"
  agent-browser click 'a[href="/abtest"]'
  agent-browser wait --url '**/abtest'
  agent-browser get url
  end=$(python3 -c 'import time; print(time.time())')
  python3 -c "print(f'{$end - $start:.2f}')"
  agent-browser close
  return 0
}

echo "=== agent-browser Benchmark ==="
for test in navigate formFill extract multiStep; do
  echo -n "$test: "
  for i in 1 2 3; do echo -n "$(bench_"$test")s "; done
  echo ""
done
```

## Crawl4AI

```python
# ~/.aidevops/.agent-workspace/work/browser-bench/bench-crawl4ai.py
# Run: source ~/.aidevops/crawl4ai-venv/bin/activate && python bench-crawl4ai.py
import asyncio, time, json
from crawl4ai import AsyncWebCrawler, BrowserConfig, CrawlerRunConfig
from crawl4ai.extraction_strategy import JsonCssExtractionStrategy

BROWSER_CONFIG = BrowserConfig(headless=True)

async def bench_navigate():
    async with AsyncWebCrawler(config=BROWSER_CONFIG) as crawler:
        start = time.time()
        result = await crawler.arun(url="https://the-internet.herokuapp.com/", config=CrawlerRunConfig(screenshot=True))
        assert result.success, f"Failed: {result.error_message}"
        return f"{time.time() - start:.2f}"

async def bench_extract():
    schema = {"name": "TableRows", "baseSelector": "table tbody tr",
              "fields": [{"name": "text", "selector": "td:first-child", "type": "text"}]}
    async with AsyncWebCrawler(config=BROWSER_CONFIG) as crawler:
        start = time.time()
        result = await crawler.arun(
            url="https://the-internet.herokuapp.com/challenging_dom",
            config=CrawlerRunConfig(extraction_strategy=JsonCssExtractionStrategy(schema)))
        assert result.success
        data = json.loads(result.extracted_content)
        assert len(data) >= 5, f"Expected 5+ rows, got {len(data)}"
        return f"{time.time() - start:.2f}"

async def run():
    results = {}
    for name, fn in [("navigate", bench_navigate), ("extract", bench_extract)]:
        times = [await fn() for _ in range(3)]
        results[name] = times
    print(json.dumps(results, indent=2))

asyncio.run(run())
```

## Stagehand

```javascript
// ~/.aidevops/.agent-workspace/work/browser-bench/bench-stagehand.mjs
import { Stagehand } from "@browserbasehq/stagehand";
import { z } from "zod";

const TESTS = {
  async navigate(sh) {
    const page = sh.ctx.pages()[0];
    await page.goto('https://the-internet.herokuapp.com/');
    await page.screenshot({ path: '/tmp/bench-sh-nav.png' });
  },
  async formFill(sh) {
    const page = sh.ctx.pages()[0];
    await page.goto('https://the-internet.herokuapp.com/login');
    await sh.act("fill the username field with tomsmith");
    await sh.act("fill the password field with SuperSecretPassword!");
    await sh.act("click the Login button");
  },
  async extract(sh) {
    const page = sh.ctx.pages()[0];
    await page.goto('https://the-internet.herokuapp.com/challenging_dom');
    const data = await sh.extract("extract the first 5 rows from the table",
      z.object({ rows: z.array(z.object({ text: z.string() })) }));
    if (data.rows.length < 5) throw new Error('Expected 5+ rows');
  },
  async multiStep(sh) {
    const page = sh.ctx.pages()[0];
    await page.goto('https://the-internet.herokuapp.com/');
    await sh.act("click the A/B Testing link");
    await page.waitForURL('**/abtest');
  }
};

async function run() {
  const results = {};
  for (const [name, fn] of Object.entries(TESTS)) {
    const times = [];
    for (let i = 0; i < 3; i++) {
      const sh = new Stagehand({ env: "LOCAL", headless: true, verbose: 0 });
      await sh.init();
      const start = performance.now();
      try { await fn(sh); times.push(((performance.now() - start) / 1000).toFixed(2)); }
      catch (e) { times.push(`ERR: ${e.message}`); }
      await sh.close();
    }
    results[name] = times;
  }
  console.log(JSON.stringify(results, null, 2));
}
run();
```

## Parallel Instance Benchmarks

### Playwright — multi-context, multi-browser, multi-page

```javascript
// bench-parallel.mjs
import { chromium } from 'playwright';

async function benchParallel() {
  const results = {};

  // Multiple contexts (same browser, cookie-isolated)
  let start = performance.now();
  const browser = await chromium.launch({ headless: true });
  const contexts = await Promise.all(Array.from({ length: 5 }, () => browser.newContext()));
  await Promise.all(contexts.map(async ctx => {
    const page = await ctx.newPage();
    await page.goto('https://the-internet.herokuapp.com/login');
  }));
  results.multiContext = `${((performance.now() - start) / 1000).toFixed(2)}s (5 contexts)`;
  await browser.close();

  // Multiple browsers (full OS-level isolation)
  start = performance.now();
  const browsers = await Promise.all(Array.from({ length: 3 }, () => chromium.launch({ headless: true })));
  await Promise.all(browsers.map(async b => {
    const page = await b.newPage();
    await page.goto('https://the-internet.herokuapp.com/');
  }));
  results.multiBrowser = `${((performance.now() - start) / 1000).toFixed(2)}s (3 browsers)`;
  await Promise.all(browsers.map(b => b.close()));

  // 10 parallel pages (shared context)
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

### agent-browser — parallel sessions

```bash
# bench-parallel-ab.sh — agent-browser parallel sessions
set -euo pipefail
start=$(python3 -c 'import time; print(time.time())')
agent-browser --session s1 open "https://the-internet.herokuapp.com/login" &
agent-browser --session s2 open "https://the-internet.herokuapp.com/checkboxes" &
agent-browser --session s3 open "https://the-internet.herokuapp.com/dropdown" &
wait
end=$(python3 -c 'import time; print(time.time())')
echo "3 parallel sessions: $(python3 -c "print(f'{$end - $start:.2f}')")s"
echo "s1: $(agent-browser --session s1 get url)"
echo "s2: $(agent-browser --session s2 get url)"
echo "s3: $(agent-browser --session s3 get url)"
agent-browser --session s1 close; agent-browser --session s2 close; agent-browser --session s3 close
```

### Crawl4AI — sequential vs parallel

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
    start = time.time()
    async with AsyncWebCrawler(config=browser_config) as crawler:
        for url in URLS: await crawler.arun(url=url, config=run_config)
    seq = time.time() - start
    start = time.time()
    async with AsyncWebCrawler(config=browser_config) as crawler:
        await crawler.arun_many(urls=URLS, config=run_config)
    par = time.time() - start
    print(f"Sequential: {seq:.2f}s | Parallel: {par:.2f}s | Speedup: {seq/par:.1f}x")

asyncio.run(run())
```

## Visual Verification Benchmark

```javascript
// bench-visual.mjs — Screenshot + AI analysis workflow timing
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
    await page.goto(url);
    await page.waitForLoadState('networkidle');
    // WARNING: Do NOT use fullPage: true for AI vision — full-page captures can exceed 8000px, crashing the session
    const screenshotPath = `/tmp/bench-visual-${Date.now()}.png`;
    await page.screenshot({ path: screenshotPath });
    const ariaSnapshot = await page.accessibility.snapshot();
    const textContent = await page.evaluate(() => document.body.innerText.substring(0, 500));
    const elapsed = ((performance.now() - start) / 1000).toFixed(2);
    results.push({
      url, expected, elapsed: `${elapsed}s`,
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

**Workflow**: Navigate → viewport screenshot (no `fullPage: true`) → ARIA snapshot → AI analyses both → decide next action.

**Key metrics**: screenshot file size (token cost), ARIA node count, time to screenshot-ready, whether ARIA alone suffices vs needing vision.
