<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Durable Objects Gotchas

## Limits

| Resource | Free | Paid |
|----------|------|------|
| Storage per DO | 10GB (SQLite) | 10GB (SQLite) |
| Total storage | 5GB | Unlimited |
| DO classes | 100 | 500 |
| Requests/sec/DO | ~1000 | ~1000 |
| CPU time | 30s default, 300s max | 30s default, 300s max |
| WebSocket message | 32MiB | 32MiB |
| SQL columns | 100 | 100 |
| SQL statement | 100KB | 100KB |
| Key+value size | 2MB | 2MB |

## Billing Gotchas

### Duration Billing Trap

DOs bill for **wall-clock time** while active, not CPU time. WebSocket open 8 hours = 8 hours billed, even if only 50 small messages were processed.

**Fix**: Use Hibernatable WebSockets API — DO sleeps while maintaining connections, only wakes (and bills) when messages arrive.

### storage.list() on Every Request

Storage reads are cheap but not free. Calling `storage.list()` or multiple `storage.get()` on every request adds up.

**Fix**: Choose the cheapest pattern for your access shape:
- `storage.get(['k1','k2','k3'])` — if you need specific keys
- `storage.list()` once on wake, cache in memory — if serving many requests per wake cycle
- Single `storage.get('allData')` with combined object — if you often need multiple keys together

### Alarm Recursion

Scheduling `setAlarm()` every 5 minutes = 288 wake-ups/day per DO. Across thousands of DOs, you're waking them all whether work exists or not.

**Fix**: Only schedule alarms when actual work is pending.

### WebSocket Never Closes

Browser tab closes without proper disconnect leave connections "open" from the DO's perspective, preventing hibernation.

**Fix**: Handle `webSocketClose` and `webSocketError` events; implement heartbeat/ping-pong to detect dead connections; use Hibernatable WebSockets API.

### Singleton vs Sharding

A global singleton DO handling all traffic never hibernates and becomes a bottleneck.

| Design | Cost Pattern |
|--------|--------------|
| One global DO | Never hibernates, continuous billing |
| Per-user DO | Each hibernates between requests |
| Per-user-per-hour | Many cold starts, many minimum durations |

**Fix**: Use per-entity DOs (per-user, per-room, per-document).

### Batching Reads and Writes

Multiple separate `storage.get()` calls cost more than one batched call. Multiple writes without intervening `await` are automatically coalesced into a single atomic transaction.

**Fix**: Batch reads with `storage.get(['k1','k2','k3','k4','k5'])`. Group writes without `await` between them.

### Hibernation State Loss

In-memory state is **lost** when a DO hibernates or evicts. Every wake is potentially cold.

**Fix**: Store all important state in SQLite storage. Use `blockConcurrencyWhile()` in the constructor to load state on wake; cache in memory for the current wake cycle only.

### Fan-Out Tax

Notifying 1,000 DOs = 1,000 DO invocations billed immediately.

**Fix**: For time-sensitive fan-out, accept the cost. For deferrable work, use Queues for retry and dead-letter handling.

### Idempotency Key Explosion

One DO per idempotency key (used once) = millions of single-use DOs that persist until deleted.

**Fix**: Hash keys into N sharded buckets; store records as rows in a single DO's SQLite table; implement TTL cleanup via alarms. Use KV instead if strong consistency isn't required.

### waitUntil() Behavior

`ctx.waitUntil()` keeps the DO alive (billed) until promises resolve. Slow external calls = paying for wait time.

**Fix**: Use alarms or Queues for true background work instead of `waitUntil()`.

### KV vs DO Storage

For read-heavy, write-rare, eventually-consistent-OK data: **KV is cheaper**.

| | KV | DO Storage |
|-|----|----|
| Reads | Global edge cache, cheap | Every read hits DO compute |
| Writes | ~60s propagation | Immediate consistency |
| Use case | Config, sessions, cache | Read-modify-write, coordination |

## Common Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| DO overloaded (503) | Single DO bottleneck | Shard with random/deterministic IDs |
| Storage quota exceeded | Write failures | Upgrade plan or cleanup via alarms |
| CPU exceeded | Terminated mid-request | Increase `limits.cpu_ms` or chunk work |
| WebSockets disconnect | Eviction | Use hibernation + reconnection logic |
| Migration failed | Deploy error | Check tag uniqueness, class names, use `--dry-run` |
| RPC not found | Old compatibility_date | Update to >= 2024-04-03 or use fetch |
| One alarm limit | Need multiple timers | Use event queue pattern (store events, single alarm) |
| Constructor expensive | Slow cold starts | Lazy load in methods, cache after first load |

## RPC vs Fetch

| | RPC | Fetch |
|-|-----|-------|
| Type safety | Full TypeScript support | Manual parsing |
| Simplicity | Direct method calls | HTTP request/response |
| Performance | Slightly faster | HTTP overhead |
| Requirement | compatibility_date >= 2024-04-03 | Always works |
| Use case | **Default choice** | Legacy, proxying |

```typescript
// RPC (recommended)
const result = await stub.myMethod(arg);

// Fetch (legacy)
const response = await stub.fetch(new Request("http://do/endpoint"));
```

## Migration Gotchas

- Tags must be unique and sequential
- No rollback mechanism
- `deleted_classes` **destroys ALL data** permanently
- Test with `--dry-run` before production deploy
- Transfers between scripts need coordination
- Renames preserve data and IDs

## Debugging

```bash
npx wrangler dev              # Local development
npx wrangler dev --remote     # Test against production DOs
npx wrangler tail             # Stream logs
npx wrangler durable-objects list
npx wrangler durable-objects info <namespace> <id>
```

```typescript
// Storage diagnostics
this.ctx.storage.sql.databaseSize  // Current storage usage
cursor.rowsRead                    // Rows scanned
cursor.rowsWritten                 // Rows modified
```
