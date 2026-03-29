# Performance Optimization

PostgreSQL and Drizzle ORM performance reference.

## Indexing

### B-Tree (Default)

Equality, range, sorting, left-anchored LIKE.

```sql
CREATE INDEX users_email_idx ON users(email);
CREATE INDEX orders_user_date_idx ON orders(user_id, created_at DESC);  -- composite (order matters)
CREATE UNIQUE INDEX users_email_unique ON users(email);
```

```typescript
export const users = pgTable('users', {
  email: text('email').notNull(),
  createdAt: timestamp('created_at').notNull(),
}, (table) => [
  index('users_email_idx').on(table.email),
  index('users_created_idx').on(table.createdAt),
]);
```

### Partial Indexes

Index only matching rows — smaller, faster.

```sql
CREATE INDEX active_users_email_idx ON users(email) WHERE deleted_at IS NULL;
CREATE INDEX pending_orders_idx ON orders(created_at) WHERE status = 'pending';
```

```typescript
index('active_users_idx').on(table.email).where(sql`deleted_at IS NULL`)
```

### Covering Indexes (INCLUDE)

```sql
CREATE INDEX orders_user_idx ON orders(user_id) INCLUDE (status, total);  -- index-only scan
```

### GIN for JSONB

| Class | Size | Operators | Best For |
|-------|------|-----------|----------|
| `jsonb_ops` (default) | 60-80% | @>, ?, ?\|, ?& | Key existence |
| `jsonb_path_ops` | 20-30% | @> only | Containment only |

```sql
CREATE INDEX data_gin_idx ON events USING gin(data);
CREATE INDEX data_gin_path_idx ON events USING gin(data jsonb_path_ops);  -- smaller
```

### Expression Indexes

Query must match expression exactly.

```sql
CREATE INDEX users_email_lower_idx ON users(lower(email));
CREATE INDEX orders_month_idx ON orders(date_trunc('month', created_at));
CREATE INDEX events_type_idx ON events((data->>'type'));
-- lower(email) = '...' uses index; email = 'UPPER@...' does NOT
```

## EXPLAIN ANALYZE

```sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM orders WHERE user_id = '123' AND status = 'pending';
```

**Key metrics:** `actual time` (ms), `rows` (estimated vs actual), `Buffers: shared hit/read` (cache vs disk).

**Red flags:** Large estimated/actual row discrepancy; high `shared read`; Seq Scan on large tables; Nested Loop with high loop count.

## Drizzle Queries

### Prepared Statements

```typescript
const getUserById = db.select().from(users)
  .where(eq(users.id, sql.placeholder('id')))
  .prepare('get_user_by_id');
const user = await getUserById.execute({ id: 'uuid-1' });
```

### N+1 Prevention

```typescript
// BAD: N+1
for (const post of posts) {
  const author = await db.select().from(users).where(eq(users.id, post.authorId));
}
// GOOD: relational query (single JOIN)
const posts = await db.query.posts.findMany({ with: { author: true } });
// GOOD: manual join
const posts = await db.select().from(posts).leftJoin(users, eq(posts.authorId, users.id));
```

### Select Only Needed Columns

```typescript
const users = await db.select({ id: users.id, email: users.email }).from(users);
const users = await db.query.users.findMany({ columns: { id: true, email: true } });
```

### Batch Operations

```typescript
// Batch insert
await db.insert(usersTable).values(users);
// Chunk large batches
const BATCH_SIZE = 1000;
for (let i = 0; i < users.length; i += BATCH_SIZE) {
  await db.insert(usersTable).values(users.slice(i, i + BATCH_SIZE));
}
// Bulk CASE update
await db.execute(sql`
  UPDATE products SET price = CASE id
    ${sql.join(updates.map(u => sql`WHEN ${u.id} THEN ${u.price}`), sql` `)}
  END WHERE id IN ${sql`(${sql.join(updates.map(u => u.id), sql`, `)})`}
`);
// Upsert
await db.insert(products).values(products).onConflictDoUpdate({
  target: products.sku,
  set: { price: sql`excluded.price`, updatedAt: new Date() },
});
```

### Transactions

```typescript
await db.transaction(async (tx) => {
  const [user] = await tx.insert(users).values({ ... }).returning();
  await tx.insert(profiles).values({ userId: user.id });
});
```

## Connection Pooling

PostgreSQL connection: ~10MB RAM. PgBouncer connection: ~2KB.

### PgBouncer

```ini
[databases]
myapp = host=localhost port=5432 dbname=myapp

[pgbouncer]
listen_port = 6432
auth_type = scram-sha-256
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 20
```

| Mode | Connection Release | Use Case |
|------|-------------------|----------|
| Session | After disconnect | Legacy apps |
| Transaction | After each transaction | Most applications |
| Statement | After each statement | Simple queries only |

**Transaction pooling limitations:** No `SET SESSION` (use `SET LOCAL`); no `PREPARE` without config; temp tables must be created/dropped in same transaction.

### Drizzle Pool Config

```typescript
const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 20, idleTimeoutMillis: 30000 });  // pg
const client = postgres(process.env.DATABASE_URL!, { max: 20, idle_timeout: 30, connect_timeout: 10 });    // postgres.js
const db = drizzle(pool, { schema });  // or drizzle(client, { schema })
```

## Caching

```typescript
async function getCachedUser(userId: string) {
  const cacheKey = `user:${userId}`;
  const cached = await redis.get(cacheKey);
  if (cached) return JSON.parse(cached);
  const user = await db.query.users.findFirst({ where: eq(users.id, userId) });
  if (user) await redis.setex(cacheKey, 3600, JSON.stringify(user));
  return user;
}
async function updateUser(userId: string, data: Partial<User>) {
  await db.update(users).set(data).where(eq(users.id, userId));
  await redis.del(`user:${userId}`);
}
```

## Pagination

```typescript
// Offset-based (simple, slow for large offsets)
db.select().from(posts).orderBy(desc(posts.createdAt)).limit(pageSize).offset((page - 1) * pageSize)
// Cursor-based (better performance)
db.select().from(posts)
  .where(cursor ? lt(posts.id, cursor) : undefined)
  .orderBy(desc(posts.id)).limit(limit)
// Keyset (most efficient — composite cursor)
db.select().from(posts)
  .where(cursor ? or(
    lt(posts.createdAt, cursor.createdAt),
    and(eq(posts.createdAt, cursor.createdAt), lt(posts.id, cursor.id))
  ) : undefined)
  .orderBy(desc(posts.createdAt), desc(posts.id)).limit(limit)
```

## Performance Checklist

| Area | Key Actions |
|------|-------------|
| **PostgreSQL config** | `shared_buffers`=25% RAM; `effective_cache_size`=50-75% RAM; `work_mem` 4-16MB (OLTP) / 64-256MB (OLAP); `io_method=worker` + `io_workers`~1/4 CPU cores (PG18) |
| **Indexing** | Index foreign keys; partial indexes for filtered subsets; covering indexes for hot queries; GIN `jsonb_path_ops` for containment; remove unused indexes |
| **Queries** | `EXPLAIN (ANALYZE, BUFFERS)` to diagnose; prepared statements for repeated queries; relational API to avoid N+1; select only needed columns; cursor pagination for large datasets |
| **Application** | Connection pooling; batch insert/update; cache frequently read data; use transactions appropriately |
| **Maintenance** | Autovacuum configured; `ANALYZE` after bulk changes; monitor table/index bloat; `REINDEX CONCURRENTLY` periodically |

## Monitoring

```sql
ALTER SYSTEM SET log_min_duration_statement = 1000;  -- log queries >1s

CREATE EXTENSION pg_stat_statements;
SELECT query, calls, mean_exec_time, total_exec_time
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 20;

SELECT t.tablename,
  pg_size_pretty(pg_table_size(t.tablename::regclass)) AS table_size,
  indexname,
  pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
  idx_scan AS scans
FROM pg_tables t
JOIN pg_stat_user_indexes i ON t.tablename = i.relname
WHERE t.schemaname = 'public'
ORDER BY pg_relation_size(indexrelid) DESC;
```
