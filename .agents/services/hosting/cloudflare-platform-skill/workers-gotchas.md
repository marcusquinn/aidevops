<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Workers Gotchas

## Runtime Constraints

**Fetch in Global Scope Is Forbidden:** All `fetch()` calls must be inside handler functions — top-level fetch errors at startup.

```typescript
// ❌ BAD — errors at startup
const config = await fetch('/config.json');

// ✅ GOOD
async fetch(req) { const config = await fetch('/config.json'); }
```

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

**CPU Budget:** 10ms standard, 30ms unbound. Use `ctx.waitUntil()` for background work, Durable Objects for heavy compute, Workers AI for ML.

**No Persistent State:** Stateless between requests — module-level variables reset unpredictably. Store state in KV, D1, or Durable Objects.

**No Node.js Built-ins by Default:** Use Workers APIs or enable compat flag.

```typescript
// ❌ BAD
import fs from 'fs';

// ✅ GOOD — Workers API or enable { "compatibility_flags": ["nodejs_compat_v2"] }
const data = await env.MY_BUCKET.get('file.txt');
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
