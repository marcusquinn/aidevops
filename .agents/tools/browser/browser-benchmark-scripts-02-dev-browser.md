# dev-browser Benchmark Scripts

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
