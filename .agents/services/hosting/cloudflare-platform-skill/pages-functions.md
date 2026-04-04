<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudflare Pages Functions

Serverless functions on Cloudflare Pages using Workers runtime. File-based routing for full-stack dev.

## File-Based Routing

```text
/functions
  ├── index.js              → /
  ├── api.js                → /api
  ├── users/
  │   ├── index.js          → /users/
  │   ├── [user].js         → /users/:user
  │   └── [[catchall]].js   → /users/*
  └── _middleware.js        → runs on all routes
```

`index.js` → directory root · trailing slash optional · specific routes precede catch-alls · falls back to static if no match

## Dynamic Routes

`[param]` → single segment (string) · `[[param]]` → multi-segment (array):

```js
// /users/[user].js — context.params.user = "nevi"
export function onRequest(context) {
  return new Response(`Hello ${context.params.user}`);
}

// /users/[[catchall]].js — context.params.catchall = ["nevi", "foobar"]
export function onRequest(context) {
  return new Response(JSON.stringify(context.params.catchall));
}
```

## Key Features

**Method handlers:** `onRequestGet`, `onRequestPost`, etc. · **Middleware:** `_middleware.js` for cross-cutting concerns · **Bindings:** KV, D1, R2, Durable Objects, Workers AI, Service bindings · **TypeScript:** `@cloudflare/workers-types` · **Advanced mode:** `_worker.js` for custom routing logic

## See Also

- [pages-functions-patterns.md](./pages-functions-patterns.md) — Auth, CORS, rate limiting, forms, caching
- [pages-functions-gotchas.md](./pages-functions-gotchas.md) — Common issues, debugging, limits
