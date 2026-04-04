<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Gotchas & Debugging

## Compatibility

### Not Supported

- Analytics Engine, Images
- Live production data / global distribution
- Some advanced Workers features

### Behavior Differences

- **No edge:** Runs in workerd locally, not Cloudflare's global network
- **Persistence:** Local filesystem/in-memory, not distributed
- **Request.cf:** Cached endpoint or mocked, not real edge metadata
- **Caching:** Local ≠ edge performance

## Common Issues

### `Cannot find module`

```js
new Miniflare({
  scriptPath: "./src/index.js",
  modules: true,
  modulesRules: [{ type: "ESModule", include: ["**/*.js"], fallthrough: true }],
});
```

### Data Lost Between Runs

Persist paths must be directories, not files:

```js
new Miniflare({
  kvPersist: "./data/kv",
  r2Persist: "./data/r2",
  durableObjectsPersist: "./data/do",
});
```

### TypeScript Workers

Cannot run `.ts` directly — build first. See [patterns.md](./patterns.md) "Build Before Tests".

### `Request.cf` Undefined

```js
new Miniflare({
  cf: true,            // fetch from Cloudflare
  // cf: "./cf.json"   // or provide custom
});
```

### `EADDRINUSE`

Use `dispatchFetch` instead of specifying a port:

```js
const mf = new Miniflare({ scriptPath: "worker.js" });
const res = await mf.dispatchFetch("http://localhost/");
```

### `ReferenceError: Counter is not defined`

DO class must be exported and name must match binding:

```js
new Miniflare({
  modules: true,
  script: `
    export class Counter { /* ... */ }
    export default { /* ... */ }
  `,
  durableObjects: { COUNTER: "Counter" },
});
```

## Debugging

```js
// Debug logging
import { Log, LogLevel } from "miniflare";
new Miniflare({ log: new Log(LogLevel.DEBUG) });

// Inspect bindings
const bindings = await mf.getBindings();
console.log(Object.keys(bindings));

// Verify KV contents
const ns = await mf.getKVNamespace("TEST");
console.log(await ns.list());
```

Prefer `dispatchFetch` over HTTP server in tests — avoids port conflicts.

## Migration

### Wrangler Dev → Miniflare

Miniflare ignores `wrangler.toml` — configure via API:

```js
new Miniflare({
  scriptPath: "dist/worker.js",
  kvNamespaces: ["KV"],
  bindings: { API_KEY: "..." },
});
```

### Miniflare 2 → 3

Different API surface, better workerd integration, changed persistence options.
See [official migration guide](https://developers.cloudflare.com/workers/testing/vitest-integration/migration-guides/migrate-from-miniflare-2/).

See [patterns.md](./patterns.md) for testing examples.
