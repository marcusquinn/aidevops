<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Gotchas & Debugging

## Common Issues

### Functions Not Invoking

All requests serve static; functions never run.

**Fix:** `/functions` at project root · `.js`/`.ts` extension · check `pages_build_output_dir` in wrangler.json · `_routes.json` not excluding paths

### Binding or Env Var Undefined

`context.env.MY_BINDING is undefined` / `context.env.VAR_NAME is undefined`

**Bindings:** Declared in wrangler.json or dashboard · name matches exactly (case-sensitive) · local dev: configure wrangler.json · redeploy after changes

**Vars/Secrets:** `vars` in wrangler.json · secrets: `.dev.vars` locally, dashboard for prod · redeploy after changes

### TypeScript Errors

Type errors for `context.env`:

```typescript
interface Env { MY_BINDING: KVNamespace; }
export const onRequest: PagesFunction<Env> = async (context) => {
  // context.env.MY_BINDING now typed
};
```

### Middleware Not Running

`_middleware.js` not executing — check: named exactly `_middleware.js` · correct directory for route scope · exports `onRequest` or method handler · calls `context.next()`

## Debugging

### Console Logging

```typescript
export async function onRequest(context) {
  console.log(context.request.method, context.request.url);
  const response = await context.next();
  console.log('Status:', response.status);
  return response;
}
```

### Wrangler Tail

```bash
npx wrangler pages deployment tail
npx wrangler pages deployment tail --status error
```

### Source Maps

```jsonc
// wrangler.json
{ "upload_source_maps": true }
```

## Limits

As of 2026-03-20 — [Cloudflare Pages Functions limits](https://developers.cloudflare.com/pages/functions/pricing/)

| Resource | Free | Paid |
|----------|------|------|
| CPU | 10ms/invocation | 30s/invocation |
| Memory | 128 MB | 128 MB |
| Script size | 3 MB compressed | 10 MB compressed |
| Env vars | 5 KB/var, 64 max | 5 KB/var, 128 max |
| Requests | 100k/day | $0.30/million |

## Best Practices

| Area | Rules |
|------|-------|
| Performance | Minimize deps for cold starts · KV for infrequent reads, D1 for relational, R2 for large files · set `Cache-Control` headers · use prepared statements and batch ops |
| Security | Never commit secrets · use secrets (encrypted) not vars for sensitive data · validate/sanitize all input · auth middleware · CORS headers · rate limit per-IP |

## Migration

### From Workers

```typescript
export default { fetch(request, env) { } }        // Worker
export function onRequest({ request, env }) { }   // Pages Function
```

In `_worker.js`: `return env.ASSETS.fetch(request)` for static assets.

### From Other Platforms

- `/functions/api/users.js` → `/api/users`
- Dynamic routes: `[param]` not `:param`
- Replace deps with Workers APIs or `nodejs_compat` flag

## Resources

- [Docs](https://developers.cloudflare.com/pages/functions/) · [Workers APIs](https://developers.cloudflare.com/workers/runtime-apis/) · [Examples](https://github.com/cloudflare/pages-example-projects) · [Discord](https://discord.gg/cloudflaredev)
- See also: [README.md](./README.md) · [patterns.md](./patterns.md)
