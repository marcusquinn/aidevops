# Cloudflare Durable Objects Storage

Persistent storage API for Durable Objects — SQLite/KV backends, PITR, automatic concurrency gates. Use cases: stateful coordination, real-time collaboration, counters, sessions, rate limiters.

## Storage Backends

| Backend | Wrangler Config | APIs | PITR |
|---------|-----------------|------|------|
| SQLite (recommended) | `new_sqlite_classes` | SQL + sync KV + async KV | ✅ |
| KV (legacy) | `new_classes` | async KV only | ❌ |

## Core APIs

| API | Access | Notes |
|-----|--------|-------|
| SQL | `ctx.storage.sql` | Full SQLite (FTS5, JSON, math) |
| Sync KV | `ctx.storage.kv` | SQLite-backed only |
| Async KV | `ctx.storage` | Both backends |
| Transactions | `transactionSync()` / `transaction()` | Never use raw `BEGIN`/`COMMIT` |
| PITR | `getBookmarkForTime()` | 30-day point-in-time recovery |
| Alarms | `setAlarm()` + `alarm()` handler | Must `deleteAlarm()` separately from `deleteAll()` |

## Quick Start

```typescript
export class Counter extends DurableObject {
  sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec("CREATE TABLE IF NOT EXISTS data(key TEXT PRIMARY KEY, value INTEGER)");
  }

  async increment(): Promise<number> {
    const row = this.sql.exec("SELECT value FROM data WHERE key = ?", "counter").one();
    const next = ((row?.value as number) || 0) + 1;
    this.sql.exec("INSERT OR REPLACE INTO data VALUES (?, ?)", "counter", next);
    return next;
  }
}
```

## See Also

- [do-storage-patterns.md](./do-storage-patterns.md) — schema migrations, caching, rate limiting, batch processing
- [do-storage-gotchas.md](./do-storage-gotchas.md) — concurrency gates, transaction rules, SQL limits, async pitfalls
- [durable-objects.md](./durable-objects.md) — DO fundamentals and coordination patterns
- [workers.md](./workers.md) — Worker runtime for DO stubs
- [d1.md](./d1.md) — shared database alternative to per-DO storage
