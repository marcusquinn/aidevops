# Playwright Benchmark Scripts

Sequential and parallel Playwright benchmark scripts. Target: `https://the-internet.herokuapp.com`. See [`browser-benchmark-scripts.md`](browser-benchmark-scripts.md) for the full suite index.

## Sequential script

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

## Parallel script — multi-context, multi-browser, multi-page throughput

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
