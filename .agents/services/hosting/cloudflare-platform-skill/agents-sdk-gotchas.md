# Agents SDK Gotchas & Best Practices
## Security and auth

- Auth **before** `conn.accept()` — unauthenticated connections can read broadcasts.
- Secrets in env bindings only; never in agent/connection state.
- Validate all client-controlled headers.

```ts
// ✅ Validate first, accept only on success
async onConnect(conn: Connection, ctx: ConnectionContext) {
  const token = (ctx.request.headers.get("Authorization") ?? "").replace("Bearer ", "");
  if (!token || !await this.validateToken(token)) { conn.close(4001, "Unauthorized"); return; }
  conn.accept();
}
```
## State discipline

- Always use `setState()` — direct `this.state` mutation skips sync and persistence.
- Keep state serializable and small; move large data to SQL.
- `conn.setState()`: per-connection metadata (userId); lost on disconnect.
- `this.setState()`: shared agent state; persisted and broadcast to all.

```ts
// ❌ this.state.count++
// ✅ this.setState({ ...this.state, count: this.state.count + 1 })
```

## SQL

- Initialize schema in `onStart()` — tables must be created before use.
- Always parameterize — tagged template literals (`this.sql`...`) auto-escape.

```ts
// ❌ this.sql`...WHERE id = '${userId}'` (Injection risk)
// ✅ this.sql`...WHERE id = ${userId}`     (Safe)
```

## Routing and entry point

- `routeAgentRequest()` in Worker `fetch` is required to route requests to agent DOs.

```ts
// ✅ export default { fetch(req, env, ctx) { return routeAgentRequest(req, env) ?? new Response("Not found", { status: 404 }); } }
```

## WebSocket lifecycle

- Call `conn.accept()` promptly to avoid client timeouts.
- Handle `onClose`/`onError` for cleanup; don't assume persistence across hibernation.
- Connection state survives hibernation; in-memory variables do not.

## Scheduling

- 1 alarm per DO — `setAlarm()` overwrites existing alarms.
- 15-minute wall-clock limit for handlers; 6 max retry attempts.
- Use `schedule()` for cron patterns; `setAlarm()` for one-shot delays.

## AI and performance

- Use AI Gateway for caching and rate limiting.
- Wrap model calls in `try/catch` with fallbacks.
- Batch `setState()` calls; limit broadcast fan-out with backpressure.

```ts
try { return await this.env.AI.run(model, { prompt }); }
catch { return { error: "Unavailable" }; }
```

## Runtime limits

| Resource | Limit |
|----------|-------|
| CPU | 30s/request (up to 5 min via `limits.cpu_ms`) |
| Memory | 128 MB/instance |
| WebSockets | 32,768/DO |
| Alarms | 1 per DO |
| SQL storage | 10 GB (shared with DO) |

## Migration

- `new_sqlite_classes` must be set when the class is **first created**.
- `deleted_classes` destroys all data permanently.
- Test migrations with `--dry-run`.

```toml
[[migrations]]
tag = "v1"
new_sqlite_classes = ["MyAgent"]
```

## Common failures

| Symptom | Cause | Fix |
|---------|-------|-----|
| "Agent not found" | Missing DO binding or `routeAgentRequest()` | Check `wrangler.toml` and entry point |
| State not syncing | Direct `this.state` mutation | Use `setState()` |
| Connect timeout | Delayed `conn.accept()` | Call `conn.accept()` immediately |
| SQL errors | Missing `onStart()` schema init | Create tables in `onStart()` |
