# Wrangler Development Patterns

Multi-step workflows. For individual commands see [wrangler.md](./wrangler.md); for pitfalls see [wrangler-gotchas.md](./wrangler-gotchas.md).

## New Worker

```bash
wrangler init my-worker && cd my-worker
wrangler dev              # Local (fast, limited accuracy)
wrangler dev --remote     # Remote (slower, production-accurate)
wrangler deploy
```

## Adding KV

```bash
wrangler kv namespace create MY_KV
wrangler kv namespace create MY_KV --preview
wrangler deploy
```

Add to `wrangler.jsonc`:

```jsonc
{ "binding": "MY_KV", "id": "abc123", "preview_id": "def456" }
```

## Adding D1

```bash
wrangler d1 create my-db
wrangler d1 migrations create my-db "initial_schema"
wrangler d1 migrations apply my-db --local
wrangler deploy
wrangler d1 migrations apply my-db --remote
```

## Multi-Environment

```jsonc
{ "env": { "staging": { "vars": { "ENV": "staging" } } } }
```

```bash
wrangler deploy --env staging
wrangler deploy --env production
```

## Integration Testing

```typescript
import { unstable_startWorker } from "wrangler";

const worker = await unstable_startWorker({ config: "wrangler.jsonc" });
const response = await worker.fetch("/api/users");
await worker.dispose();
```

## TypeScript Worker Scaffold

```bash
wrangler types  # Generate types from config
```

```typescript
interface Env {
  MY_KV: KVNamespace;
  DB: D1Database;
  API_KEY: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const value = await env.MY_KV.get("key");
    return Response.json({ value });
  }
} satisfies ExportedHandler<Env>;
```

## Durable Objects Migration

```jsonc
{ "migrations": [{ "tag": "v1", "new_sqlite_classes": ["Counter"] }] }
```

## Performance

```jsonc
{ "minify": true }
```

```typescript
// KV caching
const cached = await env.CACHE.get("key", { cacheTtl: 3600 });

// Batch D1
await env.DB.batch([
  env.DB.prepare("SELECT * FROM users"),
  env.DB.prepare("SELECT * FROM posts")
]);

// Edge caching
return new Response(data, {
  headers: { "Cache-Control": "public, max-age=3600" }
});
```
