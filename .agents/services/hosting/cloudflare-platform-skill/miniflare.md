# Miniflare

Local simulator for Cloudflare Workers. Runs Workers in workerd sandbox with full runtime API support — no internet required.

> **Most users should use Wrangler (`wrangler dev`).** Use Miniflare for advanced testing requiring programmatic control.

## When to Use

- Integration tests for Workers with bindings (KV, DO, R2, D1, Queues, WebSockets)
- Fine-grained test control: dispatch events without HTTP, simulate Worker connections
- Multiple Workers with service bindings

## Setup

```bash
npm i -D miniflare
```

Requires ES modules (`"type": "module"` in `package.json`).

## Quick Start

```js
import { Miniflare } from "miniflare";

const mf = new Miniflare({
  modules: true,
  script: `
    export default {
      async fetch(request, env, ctx) {
        return new Response("Hello Miniflare!");
      }
    }
  `,
});

const res = await mf.dispatchFetch("http://localhost:8787/");
console.log(await res.text()); // Hello Miniflare!
await mf.dispose();
```

## See Also

- [patterns.md](./patterns.md) - Testing patterns, CI, mocking
- [gotchas.md](./gotchas.md) - Compatibility issues, limits, debugging

## Resources

- [Miniflare Docs](https://developers.cloudflare.com/workers/testing/miniflare/)
- [Miniflare GitHub](https://github.com/cloudflare/workers-sdk/tree/main/packages/miniflare)
- [Vitest Integration](https://developers.cloudflare.com/workers/testing/vitest-integration/) (recommended)
