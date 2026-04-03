# Workers Gotchas

## Runtime Constraints

**CPU Budget:** Standard 10ms, Unbound 30ms. Use `ctx.waitUntil()` for background work, Durable Objects for heavy compute, Workers AI for ML.

**No Persistent State:** Workers are stateless between requests. Module-level variables reset unpredictably — store state in KV, D1, or Durable Objects.

**Response Bodies Are Streams:** Body can only be read once — clone before reuse.

```typescript
// ❌ BAD — body consumed before return
const response = await fetch(url);
await logBody(response.text());
return response;

// ✅ GOOD
const text = await response.text();
await logBody(text);
return new Response(text, response);
```

**No Node.js Built-ins by Default:** Use Workers APIs or enable compat flag.

```typescript
// ❌ BAD
import fs from 'fs';

// ✅ GOOD — Workers API
const data = await env.MY_BUCKET.get('file.txt');
// OR: { "compatibility_flags": ["nodejs_compat_v2"] }
```

**Fetch in Global Scope Is Forbidden:** Move all `fetch()` calls inside handler functions.

```typescript
// ❌ BAD — top-level fetch errors at startup
const config = await fetch('/config.json');

// ✅ GOOD — fetch inside handler
async fetch(req) {
  const config = await fetch('/config.json');
}
```

## Runtime Limits

| Resource | Limit |
|----------|-------|
| Request size | 100 MB |
| Response size | Unlimited (streaming) |
| CPU time | 10ms (standard) / 30ms (unbound) |
| Subrequests | 1000 per request |
| KV reads | 1000 per request |
| KV write size | 25 MB |
| Environment size | 5 MB |

## Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `Body has already been used` | Response body read twice | Clone before reading: `response.clone()` |
| `Too much CPU time used` | Exceeded CPU limit | Move background work into `ctx.waitUntil()` |
| `Subrequest depth limit exceeded` | Too many nested subrequests | Flatten request chain, use service bindings |

## See Also

- [workers-patterns.md](./workers-patterns.md) - Best practices
