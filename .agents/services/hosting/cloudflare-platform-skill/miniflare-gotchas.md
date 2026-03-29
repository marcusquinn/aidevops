# Gotchas & Debugging

## Compatibility Issues

### Not Supported in Miniflare

- Cloudflare Analytics Engine, Images
- Live production data / true global distribution
- Some advanced Workers features

### Behavior Differences from Production

- **No actual edge:** Runs in workerd locally, not Cloudflare's global network
- **Persistence:** Local filesystem/in-memory, not distributed
- **Request.cf:** Fetched from cached endpoint or mocked, not real edge metadata
- **Performance/Caching:** Local ≠ edge

## Common Issues

### Module Resolution (`Cannot find module`)

```js
new Miniflare({
  scriptPath: "./src/index.js",
  modules: true,
  modulesRules: [{ type: "ESModule", include: ["**/*.js"], fallthrough: true }],
});
```

### Persistence Not Working (data lost between runs)

Persist paths must be directories, not files:

```js
new Miniflare({
  kvPersist: "./data/kv",
  r2Persist: "./data/r2",
  durableObjectsPersist: "./data/do",
});
```

### TypeScript Workers (cannot run `.ts` directly)

Build first; see [patterns.md](./patterns.md) "Build Before Tests".

### Request.cf Undefined

```js
new Miniflare({
  cf: true,       // fetch from Cloudflare
  // cf: "./cf.json"  // or provide custom
});
```

### Port Already in Use (`EADDRINUSE`)

Don't specify a port for testing — use `dispatchFetch` instead:

```js
const mf = new Miniflare({ scriptPath: "worker.js" });
const res = await mf.dispatchFetch("http://localhost/");
```

### Durable Object Not Found (`ReferenceError: Counter is not defined`)

DO class must be exported and name must match binding:

```js
new Miniflare({
  modules: true,
  script: `
    export class Counter { /* ... */ }
    export default { /* ... */ }
  `,
  durableObjects: { COUNTER: "Counter" }, // matches export name
});
```

## Debugging Tips

```js
// Enable debug logging
import { Log, LogLevel } from "miniflare";
new Miniflare({ log: new Log(LogLevel.DEBUG) });

// Check binding names
const bindings = await mf.getBindings();
console.log(Object.keys(bindings));

// Verify KV storage directly
const ns = await mf.getKVNamespace("TEST");
console.log(await ns.list());
```

Use `dispatchFetch` for tests, not the HTTP server — avoids port conflicts.

## Migration Notes

### Wrangler Dev → Miniflare

Miniflare doesn't read `wrangler.toml` — configure everything via API:

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
