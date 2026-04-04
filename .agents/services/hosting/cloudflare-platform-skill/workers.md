<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudflare Workers

Cloudflare Workers run request-driven code on a global V8 isolate runtime. Prefer web platform APIs (`fetch`, `URL`, `Headers`, `Request`, `Response`) for portability.

## Best Fit

- Edge APIs, proxies, routing logic, and request/response transforms
- Authentication, authorization, rate limiting, and security layers
- Static asset optimization, feature flags, and A/B testing
- WebSocket applications and event-driven handlers

## Why Use Them

- V8 isolates instead of containers or VMs
- Cold starts under 1 ms
- Global deployment across 300+ locations
- JS/TS, Python, Rust, and WebAssembly support

## Recommended Module Worker

```typescript
export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    return new Response('Hello World!');
  },
};
```

- `request`: incoming `Request`
- `env`: bindings for KV, D1, R2, secrets, and vars
- `ctx`: `waitUntil()` and `passThroughOnException()`

## Handler Surfaces

```typescript
async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response>
async scheduled(event: ScheduledEvent, env: Env, ctx: ExecutionContext): Promise<void>
async queue(batch: MessageBatch, env: Env, ctx: ExecutionContext): Promise<void>
async tail(events: TraceItem[], env: Env, ctx: ExecutionContext): Promise<void>
```

## Wrangler Essentials

```bash
npm create cloudflare@latest my-worker -- --type hello-world
cd my-worker
npx wrangler dev                    # Local dev
npx wrangler dev --remote           # Remote dev with actual resources
npx wrangler deploy                 # Production
npx wrangler deploy --env staging   # Specific environment
npx wrangler tail                   # Stream logs
npx wrangler secret put API_KEY     # Set secret
```

## Read Next

- [workers-patterns.md](./workers-patterns.md) - Workflows, testing, and optimization
- [workers-gotchas.md](./workers-gotchas.md) - Limits, pitfalls, and troubleshooting
- [wrangler.md](./wrangler.md) - CLI details
- [kv.md](./kv.md), [d1.md](./d1.md), [r2.md](./r2.md), [durable-objects.md](./durable-objects.md), [queues.md](./queues.md) - Common bindings
- Docs: https://developers.cloudflare.com/workers/
- Examples: https://developers.cloudflare.com/workers/examples/
- Runtime APIs: https://developers.cloudflare.com/workers/runtime-apis/
