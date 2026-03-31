# Cloudflare Workers

Build request-driven edge applications on Cloudflare's V8 isolate runtime. Prefer web platform APIs for portability.

## Why Workers

- V8 isolates, not containers/VMs
- Cold starts under 1 ms
- Global deployment across 300+ locations
- Standards-based APIs: `fetch`, `URL`, `Headers`, `Request`, `Response`
- JS/TS, Python, Rust, and WebAssembly support

## Good Fits

- API endpoints at the edge
- Request/response transformation
- Authentication and authorization layers
- Static asset optimization
- A/B testing and feature flags
- Rate limiting and security
- Proxy and routing logic
- WebSocket applications

## Recommended Module Worker

```typescript
export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    return new Response('Hello World!');
  },
};
```

Handler parameters:
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

## Essential Commands

```bash
npx wrangler dev                    # Local dev
npx wrangler dev --remote           # Remote dev (actual resources)
npx wrangler deploy                 # Production
npx wrangler deploy --env staging   # Specific environment
npx wrangler tail                   # Stream logs
npx wrangler secret put API_KEY     # Set secret
```

## Quick Start

```bash
npm create cloudflare@latest my-worker -- --type hello-world
cd my-worker
npx wrangler dev
```

## Resources

- Docs: https://developers.cloudflare.com/workers/
- Examples: https://developers.cloudflare.com/workers/examples/
- Runtime APIs: https://developers.cloudflare.com/workers/runtime-apis/

## In This Reference

- [Workers Patterns](./workers-patterns.md) - Common workflows, testing, and optimization
- [Workers Gotchas](./workers-gotchas.md) - Limits, pitfalls, and troubleshooting

## See Also

- [KV](./kv.md) - Key-value storage
- [D1](./d1.md) - SQL database
- [R2](./r2.md) - Object storage
- [Durable Objects](./durable-objects.md) - Stateful coordination
- [Queues](./queues.md) - Message queues
- [Wrangler](./wrangler.md) - CLI tool reference
