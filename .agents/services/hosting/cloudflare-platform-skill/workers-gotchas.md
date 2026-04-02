# Workers Gotchas

## Design Constraints

**CPU Budget:** Standard 10ms, Unbound 30ms. Use `ctx.waitUntil()` for background work, Durable Objects for heavy compute, Workers AI for ML.

**No Persistent State:** Workers are stateless between requests. Module-level variables reset unpredictably — store persistent state in KV, D1, or Durable Objects.

**Response Bodies Are Streams:**

```typescript
// ❌ BAD
const response = await fetch(url);
await logBody(response.text());  // First read
return response;  // Body already consumed!

// ✅ GOOD
const response = await fetch(url);
const text = await response.text();
await logBody(text);
return new Response(text, response);
```

**No Node.js Built-ins by Default:**

```typescript
// ❌ BAD
import fs from 'fs';  // Not available

// ✅ GOOD - use Workers APIs
const data = await env.MY_BUCKET.get('file.txt');

// OR enable Node.js compat
{ "compatibility_flags": ["nodejs_compat_v2"] }
```

**Fetch in Global Scope Is Forbidden:**

```typescript
// ❌ BAD
const config = await fetch('/config.json');  // Error!

export default {
  async fetch() { return new Response('OK'); },
};

// ✅ GOOD
export default {
  async fetch() {
    const config = await fetch('/config.json');  // OK
    return new Response('OK');
  },
};
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
