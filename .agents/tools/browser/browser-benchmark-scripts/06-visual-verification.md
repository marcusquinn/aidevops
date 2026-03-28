# Visual Verification Benchmark Scripts

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
