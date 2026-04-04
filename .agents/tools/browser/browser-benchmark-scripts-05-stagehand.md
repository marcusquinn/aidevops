<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Stagehand Benchmark Scripts

AI-driven `act()`/`extract()`. New `Stagehand` per run (cold-start). Tests use `sh`; page: `sh.ctx.pages()[0]`.

```javascript
import { Stagehand } from "@browserbasehq/stagehand";
import { z } from "zod";

const TESTS = {
  async navigate(sh) {
    const page = sh.ctx.pages()[0];
    await page.goto('https://the-internet.herokuapp.com/');
    await page.screenshot({ path: '/tmp/bench-sh-nav.png' });
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

// Harness: new Stagehand → init → time fn(sh) → close; 3 runs, JSON output.
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
