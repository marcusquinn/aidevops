# Performance Optimization

PostgreSQL and Drizzle ORM performance reference.

## Indexing Strategies

### B-Tree (Default)

Best for: equality, range queries, sorting, LIKE with left anchor.

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

Index only rows matching a condition — smaller, faster updates, more efficient queries.

```sql
CREATE INDEX active_users_email_idx ON users(email) WHERE deleted_at IS NULL;
CREATE INDEX pending_orders_idx ON orders(created_at) WHERE status = 'pending';
```

```typescript
index('active_users_idx').on(table.email).where(sql`deleted_at IS NULL`)
```

### Covering Indexes (INCLUDE)

Include extra columns for index-only scans (no table access):

```sql
CREATE INDEX orders_user_idx ON orders(user_id) INCLUDE (status, total);
-- SELECT status, total FROM orders WHERE user_id = 123;  -- index-only scan
```

### GIN Indexes for JSONB

| Class | Size | Operators | Best For |
|-------|------|-----------|----------|
| `jsonb_ops` (default) | 60-80% | @>, ?, ?\|, ?& | Key existence |
| `jsonb_path_ops` | 20-30% | @> only | Containment only |

```sql
CREATE INDEX data_gin_idx ON events USING gin(data);
CREATE INDEX data_gin_path_idx ON events USING gin(data jsonb_path_ops);  -- smaller
```

### Expression Indexes

```sql
CREATE INDEX users_email_lower_idx ON users(lower(email));          -- case-insensitive
CREATE INDEX orders_month_idx ON orders(date_trunc('month', created_at));
CREATE INDEX events_type_idx ON events((data->>'type'));             -- JSONB field
```

**Important:** Query must match expression exactly.

```sql
SELECT * FROM users WHERE lower(email) = 'user@example.com';  -- uses index
SELECT * FROM users WHERE email = 'USER@example.com';          -- does NOT
```

## Query Optimization

### EXPLAIN ANALYZE

```sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM orders WHERE user_id = '123' AND status = 'pending';
```

**Key metrics:** `actual time` (ms), `rows` (estimated vs actual), `Buffers: shared hit/read` (cache vs disk).

**Problem indicators:** Large estimated/actual row discrepancy; high `shared read`; Seq Scan on large tables; Nested Loop with high loop count.

```sql
-- Before index: Seq Scan, Rows Removed by Filter: 999000, Buffers: shared read=40000
-- After index:  Index Scan using orders_user_status_idx, Buffers: shared hit=10
```

## Drizzle Query Optimization

### Prepared Statements

```typescript
const getUserById = db.select().from(users)
  .where(eq(users.id, sql.placeholder('id')))
  .prepare('get_user_by_id');

const user = await getUserById.execute({ id: 'uuid-1' });  // reuses plan
```

### Avoid N+1 Queries

```typescript
// Bad: N+1
for (const post of posts) {
  const author = await db.select().from(users).where(eq(users.id, post.authorId));
}

// Good: relational query (single JOIN)
const posts = await db.query.posts.findMany({ with: { author: true } });

// Good: manual join
const posts = await db.select().from(posts).leftJoin(users, eq(posts.authorId, users.id));
```

### Select Only Needed Columns

```typescript
// Bad
const users = await db.select().from(users);

// Good
const users = await db.select({ id: users.id, email: users.email }).from(users);
const users = await db.query.users.findMany({ columns: { id: true, email: true } });
```

### Batch Operations

```typescript
// Bad: individual inserts in a loop
// Good: batch insert
await db.insert(usersTable).values(users);

// Very large batches: chunk
const BATCH_SIZE = 1000;
for (let i = 0; i < users.length; i += BATCH_SIZE) {
  await db.insert(usersTable).values(users.slice(i, i + BATCH_SIZE));
}
```

### Transactions

```typescript
// Good: single transaction (atomic, one round trip)
await db.transaction(async (tx) => {
  const [user] = await tx.insert(users).values({ ... }).returning();
  await tx.insert(profiles).values({ userId: user.id });
});
```

## Connection Pooling

Each PostgreSQL connection uses ~10MB RAM. PgBouncer connections use ~2KB.

### PgBouncer Configuration

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

### Drizzle Connection Pooling

```typescript
// postgres.js (built-in pooling)
const client = postgres(process.env.DATABASE_URL!, { max: 20, idle_timeout: 30, connect_timeout: 10 });

// node-postgres
const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 20, idleTimeoutMillis: 30000 });
const db = drizzle(pool, { schema });
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

// Invalidate on update
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

// Keyset pagination (most efficient — composite cursor)
db.select().from(posts)
  .where(cursor ? or(
    lt(posts.createdAt, cursor.createdAt),
    and(eq(posts.createdAt, cursor.createdAt), lt(posts.id, cursor.id))
  ) : undefined)
  .orderBy(desc(posts.createdAt), desc(posts.id)).limit(limit)
```

## Bulk Operations

```typescript
// Bulk insert
await db.insert(events).values(items.map(item => ({ type: item.type, data: item.data, createdAt: new Date() })));

// Bulk update with CASE
await db.execute(sql`
  UPDATE products SET price = CASE id
    ${sql.join(updates.map(u => sql`WHEN ${u.id} THEN ${u.price}`), sql` `)}
  END WHERE id IN ${sql`(${sql.join(updates.map(u => u.id), sql`, `)})`}
`);

// Bulk upsert
await db.insert(products).values(products).onConflictDoUpdate({
  target: products.sku,
  set: { price: sql`excluded.price`, updatedAt: new Date() },
});
```

## Performance Checklist

**PostgreSQL config:**
- `shared_buffers` = 25% of RAM
- `effective_cache_size` = 50-75% of RAM
- `work_mem`: OLTP 4-16MB, OLAP 64-256MB
- `io_method = worker` + `io_workers` ~1/4 CPU cores (PostgreSQL 18)

**Indexing:** Foreign keys indexed; partial indexes for filtered subsets; covering indexes for hot queries; GIN `jsonb_path_ops` for JSONB containment; remove unused indexes.

**Queries:** `EXPLAIN (ANALYZE, BUFFERS)` for optimization; prepared statements for repeated queries; relational queries API to avoid N+1; select only needed columns; cursor-based pagination for large datasets.

**Application:** Connection pooling; batch insert/update; cache frequently accessed data; use transactions appropriately.

**Maintenance:** Autovacuum configured; `ANALYZE` after bulk changes; monitor table/index bloat; `REINDEX CONCURRENTLY` periodically.

## Monitoring

```sql
-- Slow query logging
ALTER SYSTEM SET log_min_duration_statement = 1000;  -- 1 second

-- Top queries by time (requires pg_stat_statements extension)
CREATE EXTENSION pg_stat_statements;
SELECT query, calls, mean_exec_time, total_exec_time
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 20;

-- Index efficiency
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
