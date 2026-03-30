# Gotchas & Best Practices

## Security first

- DO: Validate/sanitize input, require WS auth, keep secrets in env bindings.
- DON'T: Trust headers blindly, expose sensitive data, or store secrets in state.

```ts
async onConnect(conn: Connection, ctx: ConnectionContext) {
  const auth = ctx.request.headers.get("Authorization") ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : null;
  if (!token || !await this.validateToken(token)) { conn.close(4001, "Unauthorized"); return; }
  conn.accept();
}
```

## State

- DO: Use `setState()` (auto-sync), keep state serializable/small, move large data to SQL.
- DON'T: Mutate `this.state` directly or store functions/circular objects.

```ts
// ❌ this.state.count++ | ✅ this.setState({...this.state, count: this.state.count + 1})
```

## SQL

- DO: Parameterize queries, initialize schema in `onStart()`, use explicit types when possible.
- DON'T: Interpolate input directly or assume tables already exist.

```ts
// ❌ this.sql`...WHERE id = '${userId}'` | ✅ this.sql`...WHERE id = ${userId}`
```

## WebSocket lifecycle

- DO: Call `conn.accept()` promptly, handle errors, clean up on disconnect.
- DON'T: Assume persistence or keep sensitive data in connection state.

```ts
async onConnect(conn: Connection, ctx: ConnectionContext) { conn.accept(); conn.setState({sessionRef: "sess_abc123"}); }
```

## Scheduling constraints

- Limits: 1 alarm at a time per DO (new `setAlarm()` overwrites prior); retries use exponential backoff (up to 6 attempts); alarm handler wall-clock limit 15 min.
- Practice: clean stale schedules, use descriptive names, handle failures.

```ts
async checkSchedules() { const schedules = await this.getSchedules(); if (schedules.length > 0) console.log("Active schedule:", schedules[0]); }
```

## AI reliability and performance

- Optimize with AI Gateway cache, streaming, and rate limiting.
- Use `try/catch` + fallback for quota/timeout/provider errors.
- Batch `setState()` writes; reduce write frequency.
- Limit broadcast fan-out, prefer selective sends, apply backpressure.

```ts
try { return await this.env.AI.run(model, {prompt}); } catch (e) { return {error: "Unavailable"}; }
```

## Limits, debugging, migration

- Runtime limits: CPU 30s/request (configurable to 5 min via `limits.cpu_ms`), memory 128MB/instance, SQL shares DO quota, 1 alarm/DO, max 32,768 WS connections/DO (practical limit lower due to CPU/memory).
- Debug: `npx wrangler dev` (local), `npx wrangler tail` (remote).
- Common failures: "Agent not found" (DO binding), state not syncing (`setState()`), connect timeout (`conn.accept()`), startup SQL errors (`onStart()` init).
- Migration: SQLite backend must be enabled at class creation (`new_sqlite_classes`); cannot be added to an existing deployed class. Test in staging; delete migrations are destructive and permanent.

```toml
[[migrations]]
tag = "v1"
new_sqlite_classes = ["MyAgent"]
```
