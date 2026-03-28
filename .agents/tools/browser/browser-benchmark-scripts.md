# Browser Benchmark Scripts

Reference scripts for `browser-benchmark.md`. All implement the same four tests (navigate, formFill, extract, multiStep) against `https://the-internet.herokuapp.com` — 3 runs each, median reported.

## Playwright (canonical reference)

```javascript
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
      trs.slice(0, 5).map(tr => tr.textContent.trim()));
    if (rows.length < 5) throw new Error('Expected 5+ rows');
  },
  async multiStep(page) {
    await page.goto('https://the-internet.herokuapp.com/');
    await page.click('a[href="/abtest"]');
    await page.waitForURL('**/abtest');
    if (!await page.title()) throw new Error('No title on target page');
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

Same tests as Playwright, adapted for persistent Chrome via CDP: `connect("http://localhost:9222")` instead of `chromium.launch()`, `waitForPageLoad(page)` after every `goto()`, `client.disconnect()` for cleanup, no per-run `page.close()`, multiStep omits title assertion.

```typescript
import { connect, waitForPageLoad } from "@/client.js";
import type { Page } from "playwright";
// TESTS: same as Playwright + waitForPageLoad(page) after each goto(), typed Page params.
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

CLI-based. Uses `_time` helper to avoid repeating timing boilerplate per test.

```bash
#!/bin/bash
set -euo pipefail

_time() { local s e; s=$(python3 -c 'import time; print(time.time())'); "$@"; e=$(python3 -c 'import time; print(time.time())'); python3 -c "print(f'{$e - $s:.2f}')"; return 0; }

bench_navigate() { agent-browser open "https://the-internet.herokuapp.com/"; agent-browser screenshot /tmp/bench-ab-nav.png; agent-browser close; return 0; }
bench_formFill() { agent-browser open "https://the-internet.herokuapp.com/login"; agent-browser snapshot -i; agent-browser fill '@username' 'tomsmith'; agent-browser fill '@password' 'SuperSecretPassword!'; agent-browser click '@submit'; agent-browser wait --url '**/secure'; agent-browser close; return 0; }
bench_extract() { agent-browser open "https://the-internet.herokuapp.com/challenging_dom"; agent-browser eval "JSON.stringify([...document.querySelectorAll('table tbody tr')].slice(0,5).map(r=>r.textContent.trim()))"; agent-browser close; return 0; }
bench_multiStep() { agent-browser open "https://the-internet.herokuapp.com/"; agent-browser click 'a[href="/abtest"]'; agent-browser wait --url '**/abtest'; agent-browser get url; agent-browser close; return 0; }

echo "=== agent-browser Benchmark ==="
for test in navigate formFill extract multiStep; do
  echo -n "$test: "; for i in 1 2 3; do echo -n "$(_time bench_"$test")s "; done; echo ""
done
```

## Crawl4AI

Only supports navigate and extract (no form interaction or multi-step navigation).

```python
import asyncio, time, json
from crawl4ai import AsyncWebCrawler, BrowserConfig, CrawlerRunConfig
from crawl4ai.extraction_strategy import JsonCssExtractionStrategy

BC = BrowserConfig(headless=True)

async def bench_navigate():
    async with AsyncWebCrawler(config=BC) as c:
        s = time.time()
        r = await c.arun(url="https://the-internet.herokuapp.com/", config=CrawlerRunConfig(screenshot=True))
        assert r.success, f"Failed: {r.error_message}"
        return f"{time.time() - s:.2f}"

async def bench_extract():
    schema = {"name": "TableRows", "baseSelector": "table tbody tr",
              "fields": [{"name": "text", "selector": "td:first-child", "type": "text"}]}
    async with AsyncWebCrawler(config=BC) as c:
        s = time.time()
        r = await c.arun(url="https://the-internet.herokuapp.com/challenging_dom",
            config=CrawlerRunConfig(extraction_strategy=JsonCssExtractionStrategy(schema)))
        assert r.success
        data = json.loads(r.extracted_content)
        assert len(data) >= 5, f"Expected 5+ rows, got {len(data)}"
        return f"{time.time() - s:.2f}"

async def run():
    results = {n: [await f() for _ in range(3)] for n, f in [("navigate", bench_navigate), ("extract", bench_extract)]}
    print(json.dumps(results, indent=2))

asyncio.run(run())
```

## Stagehand

Uses AI-driven `act()` / `extract()` instead of CSS selectors. Same harness as Playwright but creates a new `Stagehand({ env: "LOCAL", headless: true, verbose: 0 })` per run (measures cold-start). Tests receive `sh` instead of `page`; access page via `sh.ctx.pages()[0]`.

```javascript
import { Stagehand } from "@browserbasehq/stagehand";
import { z } from "zod";

const TESTS = {
  async navigate(sh) {
    await sh.ctx.pages()[0].goto('https://the-internet.herokuapp.com/');
    await sh.ctx.pages()[0].screenshot({ path: '/tmp/bench-sh-nav.png' });
  },
  async formFill(sh) {
    await sh.ctx.pages()[0].goto('https://the-internet.herokuapp.com/login');
    await sh.act("fill the username field with tomsmith");
    await sh.act("fill the password field with SuperSecretPassword!");
    await sh.act("click the Login button");
  },
  async extract(sh) {
    await sh.ctx.pages()[0].goto('https://the-internet.herokuapp.com/challenging_dom');
    const data = await sh.extract("extract the first 5 rows from the table",
      z.object({ rows: z.array(z.object({ text: z.string() })) }));
    if (data.rows.length < 5) throw new Error('Expected 5+ rows');
  },
  async multiStep(sh) {
    await sh.ctx.pages()[0].goto('https://the-internet.herokuapp.com/');
    await sh.act("click the A/B Testing link");
    await sh.ctx.pages()[0].waitForURL('**/abtest');
  }
};

// Harness: same as Playwright — iterate TESTS, 3 runs, JSON output.
// Per run: sh = new Stagehand(...); sh.init(); <time fn(sh)>; sh.close().
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

## Parallel Benchmarks

### Playwright — multi-context, multi-browser, multi-page

```javascript
import { chromium } from 'playwright';
const URL = 'https://the-internet.herokuapp.com/';
const elapsed = (s) => ((performance.now() - s) / 1000).toFixed(2);

async function benchParallel() {
  const results = {};

  let s = performance.now();
  let b = await chromium.launch({ headless: true });
  const ctxs = await Promise.all(Array.from({ length: 5 }, () => b.newContext()));
  await Promise.all(ctxs.map(async c => { await (await c.newPage()).goto(URL + 'login'); }));
  results.multiContext = `${elapsed(s)}s (5 contexts)`;
  await b.close();

  s = performance.now();
  const bs = await Promise.all(Array.from({ length: 3 }, () => chromium.launch({ headless: true })));
  await Promise.all(bs.map(async b => { await (await b.newPage()).goto(URL); }));
  results.multiBrowser = `${elapsed(s)}s (3 browsers)`;
  await Promise.all(bs.map(b => b.close()));

  s = performance.now();
  b = await chromium.launch({ headless: true });
  const ctx = await b.newContext();
  await Promise.all(Array.from({ length: 10 }, async () => { await (await ctx.newPage()).goto(URL); }));
  results.multiPage = `${elapsed(s)}s (10 pages)`;
  await b.close();

  console.log(JSON.stringify(results, null, 2));
}
benchParallel();
```

### agent-browser — 3 parallel sessions

```bash
set -euo pipefail
start=$(python3 -c 'import time; print(time.time())')
agent-browser --session s1 open "https://the-internet.herokuapp.com/login" &
agent-browser --session s2 open "https://the-internet.herokuapp.com/checkboxes" &
agent-browser --session s3 open "https://the-internet.herokuapp.com/dropdown" &
wait
end=$(python3 -c 'import time; print(time.time())')
echo "3 parallel sessions: $(python3 -c "print(f'{$end - $start:.2f}')")s"
for s in s1 s2 s3; do echo "$s: $(agent-browser --session "$s" get url)"; done
for s in s1 s2 s3; do agent-browser --session "$s" close; done
```

### Crawl4AI — sequential vs parallel

```python
import asyncio, time
from crawl4ai import AsyncWebCrawler, BrowserConfig, CrawlerRunConfig

URLS = ["https://the-internet.herokuapp.com/" + p for p in ["login", "checkboxes", "dropdown", "tables", "frames"]]

async def run():
    bc, rc = BrowserConfig(headless=True), CrawlerRunConfig(screenshot=True)
    s = time.time()
    async with AsyncWebCrawler(config=bc) as c:
        for u in URLS: await c.arun(url=u, config=rc)
    seq = time.time() - s
    s = time.time()
    async with AsyncWebCrawler(config=bc) as c:
        await c.arun_many(urls=URLS, config=rc)
    par = time.time() - s
    print(f"Sequential: {seq:.2f}s | Parallel: {par:.2f}s | Speedup: {seq/par:.1f}x")

asyncio.run(run())
```

## Visual Verification Benchmark

Screenshot + ARIA snapshot workflow timing. WARNING: Do NOT use `fullPage: true` — can exceed 8000px and crash the session. Workflow: navigate → viewport screenshot → ARIA snapshot → AI analyses both → decide next action. Key metrics: screenshot file size (token cost), ARIA node count, time to screenshot-ready.

```javascript
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
    const p = `/tmp/bench-visual-${Date.now()}.png`;
    await page.screenshot({ path: p });
    const aria = await page.accessibility.snapshot();
    const text = await page.evaluate(() => document.body.innerText.substring(0, 500));
    results.push({ url, expected, elapsed: `${((performance.now() - start) / 1000).toFixed(2)}s`,
      screenshotSize: `${(fs.statSync(p).size / 1024).toFixed(0)}KB`,
      ariaNodes: aria?.children?.length || 0, textPreview: text.substring(0, 100) });
    await page.close();
  }
  await browser.close();
  console.log(JSON.stringify(results, null, 2));
}
benchVisual();
```
