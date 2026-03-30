# Gotchas & Best Practices

## Security first

- DO: Validate/sanitize input, require WS auth, keep secrets in env bindings.
- DON'T: Trust headers blindly, expose sensitive data, or store secrets in state.

```ts
async onConnect(conn: Connection, ctx: ConnectionContext) {
  const token = ctx.request.headers.get("Authorization");
  if (!await this.validateToken(token)) { conn.close(4001, "Unauthorized"); return; }
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
async onConnect(conn: Connection, ctx: ConnectionContext) { conn.accept(); conn.setState({userId: "123"}); }
```

## Scheduling constraints

- Limits: max 1000 schedules/agent, minimum interval 1 minute, schedules persist.
- Practice: clean stale schedules, use descriptive names, handle failures.

```ts
async checkSchedules() { if ((await this.getSchedules()).length > 800) console.warn("Near limit!"); }
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

- Runtime limits: CPU 30s/request, memory 128MB/instance, SQL shares DO quota, schedules 1000/agent; WS connections have no hard cap but are memory-bound.
- Debug: `npx wrangler dev` (local), `npx wrangler tail` (remote).
- Common failures: "Agent not found" (DO binding), state not syncing (`setState()`), connect timeout (`conn.accept()`), startup SQL errors (`onStart()` init).
- Migration: use `new_sqlite_classes`, test in staging, and avoid downgrades after SQL migration.

```toml
[[migrations]]
tag = "v1"
new_sqlite_classes = ["MyAgent"]
```
