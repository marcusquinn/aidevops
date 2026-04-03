# Hyperdrive Patterns

## High-Traffic Reads
Cache trending content (~60s) and use pooling to absorb spikes.
```typescript
const sql = postgres(env.HYPERDRIVE.connectionString, {max: 5, prepare: true});
const posts = await sql`SELECT * FROM posts WHERE published = true ORDER BY views DESC LIMIT 20`;
const [user] = await sql`SELECT id, username, bio FROM users WHERE id = ${userId}`;
```

## Mixed Read/Write
Use separate bindings for cached reads and realtime writes.
```typescript
interface Env {
  HYPERDRIVE_CACHED: Hyperdrive;    // max_age=120
  HYPERDRIVE_REALTIME: Hyperdrive;  // caching disabled
}
if (req.method === "GET") {
  const sql = postgres(env.HYPERDRIVE_CACHED.connectionString, {prepare: true});
  const products = await sql`SELECT * FROM products WHERE category = ${cat}`;
}
if (req.method === "POST") {
  const sql = postgres(env.HYPERDRIVE_REALTIME.connectionString, {prepare: true});
  await sql`INSERT INTO orders ${sql(data)}`;
}
```

## Analytics Dashboard
Cache expensive aggregations for instant loads and reduced DB pressure.
```typescript
const client = new Client({connectionString: env.HYPERDRIVE.connectionString});
await client.connect();
const dailyStats = await client.query(`
  SELECT DATE(created_at) as date, COUNT(*) as orders, SUM(amount) as revenue
  FROM orders WHERE created_at >= NOW() - INTERVAL '30 days'
  GROUP BY DATE(created_at) ORDER BY date DESC
`);
const topProducts = await client.query(`
  SELECT p.name, COUNT(oi.id) as count, SUM(oi.quantity * oi.price) as revenue
  FROM order_items oi JOIN products p ON oi.product_id = p.id
  WHERE oi.created_at >= NOW() - INTERVAL '7 days'
  GROUP BY p.id, p.name ORDER BY revenue DESC LIMIT 10
`);
```

## Multi-Tenant
Per-tenant caching with shared pooling protects DB from multi-tenant load.
```typescript
const tenantId = req.headers.get("X-Tenant-ID");
const sql = postgres(env.HYPERDRIVE.connectionString, {prepare: true});
const docs = await sql`
  SELECT * FROM documents
  WHERE tenant_id = ${tenantId} AND deleted_at IS NULL
  ORDER BY updated_at DESC LIMIT 50
`;
```

## Geographically Distributed
Edge setup + DB-side pooling = global access to single-region DB without replication.
```typescript
const sql = postgres(env.HYPERDRIVE.connectionString, {prepare: true});
const [user] = await sql`SELECT * FROM users WHERE id = ${userId}`;
return Response.json({user, serverRegion: req.cf?.colo});
```

## Connection Pooling
Transaction mode: connection acquired per transaction, `RESET` on return. SET statements must stay within a single transaction or compound statement; keep transactions short.

```typescript
// ✅ SET within transaction (RESET after COMMIT)
await client.query("BEGIN");
await client.query("SET work_mem = '256MB'");
await client.query("SELECT * FROM large_table");
await client.query("COMMIT");
// ✅ Compound statement
await client.query("SET work_mem = '256MB'; SELECT * FROM large_table");
// ❌ Across queries — may get different connection
await client.query("SET work_mem = '256MB'");
await client.query("SELECT * FROM large_table");  // SET not applied
// ✅ Short transaction
await client.query("BEGIN");
await client.query("UPDATE users SET status = $1 WHERE id = $2", [status, id]);
await client.query("COMMIT");
// ✅ SET LOCAL scoped to transaction
await client.query("BEGIN");
await client.query("SET LOCAL work_mem = '256MB'");
await client.query("SELECT * FROM large_table");
await client.query("COMMIT");
// ❌ Long transaction holds connection
await client.query("BEGIN");
await processThousands();
await client.query("COMMIT");
```

## Performance Tips

**Connection settings** — always enable prepared statements; tune per Worker:
```typescript
const sql = postgres(connectionString, {
  max: 5,             // Limit per Worker
  fetch_types: false, // Skip if not using arrays
  prepare: true,      // Cached plans; false adds extra round-trips
  idle_timeout: 60,   // Match Worker lifetime
});
```

**Cache-friendly queries** — use deterministic expressions:
```typescript
// ✅ Deterministic — cacheable
await sql`SELECT * FROM products WHERE category = 'electronics' LIMIT 10`;
// ❌ Volatile — not cacheable
await sql`SELECT * FROM logs WHERE created_at > NOW()`;
// ✅ Parameterize volatile parts
const ts = Date.now();
await sql`SELECT * FROM logs WHERE created_at > ${ts}`;
```

**Monitor cache hits:**
```typescript
const start = Date.now();
const result = await sql`SELECT * FROM users LIMIT 10`;
console.log({duration: Date.now() - start, likelyCached: Date.now() - start < 10});  // <10ms = likely cache hit
```

See [hyperdrive-gotchas.md](./hyperdrive-gotchas.md) for limits and troubleshooting.
