# Stagehand Benchmark Scripts

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
