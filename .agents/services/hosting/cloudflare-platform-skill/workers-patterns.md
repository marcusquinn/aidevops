# Workers Patterns

For basics and handler signatures, see [workers.md](./workers.md).

## Error Handling

```typescript
class HTTPError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await handleRequest(request, env);
    } catch (error) {
      if (error instanceof HTTPError) {
        return new Response(JSON.stringify({ error: error.message }), {
          status: error.status, headers: { 'Content-Type': 'application/json' }
        });
      }
      return new Response('Internal Server Error', { status: 500 });
    }
  },
};
```

## CORS

```typescript
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

if (request.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
// Spread corsHeaders into final Response headers
```

## Routing

```typescript
const router = { 'GET /api/users': handleGetUsers, 'POST /api/users': handleCreateUser };

const handler = router[`${request.method} ${url.pathname}`];
return handler ? handler(request, env) : new Response('Not Found', { status: 404 });
```

**Production**: Use Hono, itty-router, or Worktop.

## Performance

```typescript
// Sequential (slow)
const user = await fetch('/api/user/1');
const posts = await fetch('/api/posts?user=1');
// Parallel (fast)
const [user, posts] = await Promise.all([fetch('/api/user/1'), fetch('/api/posts?user=1')]);
```

## Streaming

```typescript
// ReadableStream — yield control every N items to avoid CPU time limit
const stream = new ReadableStream({
  async start(controller) {
    for (let i = 0; i < 1000; i++) {
      controller.enqueue(new TextEncoder().encode(`Item ${i}\n`));
      if (i % 100 === 0) await new Promise(r => setTimeout(r, 0));
    }
    controller.close();
  }
});

// Transform pipeline
response.body.pipeThrough(new TextDecoderStream()).pipeThrough(
  new TransformStream({ transform(chunk, c) { c.enqueue(chunk.toUpperCase()); } })
).pipeThrough(new TextEncoderStream());
```

## Testing

```typescript
import { describe, it, expect } from 'vitest';
import worker from '../src/index';

describe('Worker', () => {
  it('returns 200', async () => {
    const req = new Request('http://localhost/');
    const env = { MY_VAR: 'test' };
    const ctx = { waitUntil: () => {}, passThroughOnException: () => {} };
    expect((await worker.fetch(req, env, ctx)).status).toBe(200);
  });
});
```

## Deployment

```bash
npx wrangler versions upload --message "Add feature"  # gradual rollout
npx wrangler rollback                                  # revert last deploy
```

For `wrangler deploy` and environment-specific deploys, see [workers.md](./workers.md).

## Monitoring

```typescript
// Track latency and status via Analytics Engine
const start = Date.now();
const response = await handleRequest(request, env);
ctx.waitUntil(env.ANALYTICS.writeDataPoint({
  doubles: [Date.now() - start], blobs: [request.url, String(response.status)]
}));
```

## Security

```typescript
const security = { 'X-Content-Type-Options': 'nosniff', 'X-Frame-Options': 'DENY', 'Content-Security-Policy': "default-src 'self'" };

const auth = request.headers.get('Authorization');
if (!auth?.startsWith('Bearer ')) return new Response('Unauthorized', { status: 401 });
```

## Gradual Rollouts

```typescript
// Hash-based feature flag — deterministic per user
const hash = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(userId));
const bucket = new Uint8Array(hash)[0] % 100;
if (bucket < rolloutPercent) return newFeature(request);
```

## See Also

- [Gotchas](./workers-gotchas.md) — common issues and limits
- [Durable Objects patterns](./durable-objects-patterns.md) — stateful rate-limiting
