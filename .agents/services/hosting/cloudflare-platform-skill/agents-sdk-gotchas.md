# Gotchas & Best Practices

## Security and auth first

- Validate/sanitize input, require WebSocket auth before `conn.accept()`, and keep secrets in env bindings.
- Don't trust client-controlled headers blindly, expose sensitive data, or store secrets in agent/connection state.

```ts
async onConnect(conn: Connection, ctx: ConnectionContext) {
  const auth = ctx.request.headers.get("Authorization") ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : null;
  if (!token || !await this.validateToken(token)) { conn.close(4001, "Unauthorized"); return; }
  conn.accept();
}
```

## State and SQL discipline

- Use `setState()` for auto-sync, keep state serializable/small, and move large data to SQL.
- Don't mutate `this.state` directly or store functions/circular objects.
- Initialize schema in `onStart()`, parameterize queries, and use explicit types when possible.
- Don't interpolate user input into SQL or assume tables already exist.

```ts
// ❌ this.state.count++ | ✅ this.setState({...this.state, count: this.state.count + 1})
```

```ts
// ❌ this.sql`...WHERE id = '${userId}'` | ✅ this.sql`...WHERE id = ${userId}`
```

## WebSocket lifecycle

- Call `conn.accept()` promptly, handle errors, and clean up on disconnect.
- Don't assume persistence or keep sensitive data in connection state.

```ts
async onConnect(conn: Connection, ctx: ConnectionContext) { conn.accept(); conn.setState({sessionRef: "sess_abc123"}); }
```

## Scheduling constraints

- Only 1 alarm exists per DO; a new `setAlarm()` overwrites the prior alarm.
- Retries use exponential backoff for up to 6 attempts, and alarm handlers have a 15-minute wall-clock limit.
- Clean stale schedules, use descriptive names, and handle failures.

```ts
async checkSchedules() { const schedules = await this.getSchedules(); if (schedules.length > 0) console.log("Active schedule:", schedules[0]); }
```

## AI reliability and performance

- Prefer AI Gateway cache, streaming, and rate limiting.
- Wrap model calls in `try/catch` with quota/timeout/provider fallbacks.
- Batch `setState()` writes, reduce write frequency, and limit broadcast fan-out with backpressure/selective sends.

```ts
try { return await this.env.AI.run(model, {prompt}); } catch (e) { return {error: "Unavailable"}; }
```

## Limits, debugging, and migration

- Runtime limits: CPU 30s/request (configurable to 5 min via `limits.cpu_ms`), memory 128MB/instance, SQL shares DO quota, 1 alarm/DO, max 32,768 WebSocket connections/DO; practical limits are lower due to CPU/memory.
- Debug with `npx wrangler dev` locally and `npx wrangler tail` remotely.
- Common failures: "Agent not found" (DO binding), state not syncing (`setState()`), connect timeout (`conn.accept()`), startup SQL errors (`onStart()` init).
- SQLite backend migrations must enable `new_sqlite_classes` when the class is first created; you cannot add it to an existing deployed class. Test in staging; delete migrations are destructive and permanent.

```toml
[[migrations]]
tag = "v1"
new_sqlite_classes = ["MyAgent"]
```
