# Wrangler Development Patterns

## New Worker / Local Dev

```bash
wrangler init my-worker && cd my-worker
wrangler dev              # Local (fast, limited accuracy)
wrangler dev --remote     # Remote (slower, production-accurate)
wrangler dev --env staging
wrangler dev --port 8787
wrangler deploy
```

## Secrets

**Never commit secrets.** Use `wrangler secret put` for production, `.dev.vars` for local.

```bash
echo "secret-value" | wrangler secret put SECRET_KEY
wrangler secret list
wrangler secret delete SECRET_KEY
```

`.dev.vars` (gitignored):

```
SECRET_KEY=local-dev-key
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

```bash
wrangler deploy --env staging
wrangler deploy --env production
```

```jsonc
{ "env": { "staging": { "vars": { "ENV": "staging" } } } }
```

## Testing

```typescript
import { unstable_startWorker } from "wrangler";

const worker = await unstable_startWorker({ config: "wrangler.jsonc" });
const response = await worker.fetch("/api/users");
await worker.dispose();
```

## Monitoring

```bash
wrangler tail                 # Real-time logs
wrangler tail --status error
wrangler tail --env production
wrangler whoami
```

## Version Control

```bash
wrangler versions list
wrangler deployments list
wrangler rollback [id]
```

## TypeScript

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

## See Also

- [wrangler.md](./wrangler.md) - Commands
- [wrangler-gotchas.md](./wrangler-gotchas.md) - Issues
