# PostgreSQL 18 Features & Configuration

## New Features

### Asynchronous I/O

AIO enables concurrent reads; up to 3x improvement for sequential scans (sequential scans, bitmap heap scans, VACUUM).

| io_method | Description | Best For |
|-----------|-------------|----------|
| `sync` | PostgreSQL 17 behavior | Compatibility |
| `worker` | Background workers (default) | Most workloads |
| `io_uring` | Linux kernel 5.1+ | Cold cache workloads |

```sql
ALTER SYSTEM SET io_method = 'worker';
ALTER SYSTEM SET io_workers = 12;           -- ~1/4 of CPU cores
ALTER SYSTEM SET effective_io_concurrency = 32;
ALTER SYSTEM SET maintenance_io_concurrency = 16;
```

### Index Skip Scan

B-tree indexes support skip scan for queries omitting leading columns (~40% faster vs full table scan).

```sql
CREATE INDEX orders_region_status_date ON orders(region, status, created_at);
SELECT * FROM orders WHERE status = 'pending';  -- uses skip scan
```

### UUIDv7

Timestamp-ordered UUIDs: chronologically sortable, better B-tree performance, reduced fragmentation. `SELECT uuidv7(); -- 019470a8-...`

In Drizzle: `id: uuid('id').primaryKey().default(sql\`uuidv7()\`)`

### Virtual Generated Columns

```sql
CREATE TABLE products (
  price numeric NOT NULL,
  tax_rate numeric NOT NULL,
  total_price numeric GENERATED ALWAYS AS (price * (1 + tax_rate)) STORED,  -- stored, indexable
  display_price text GENERATED ALWAYS AS (price::text || ' USD')             -- computed at read only
);
```

### Temporal Constraints

`WITHOUT OVERLAPS` prevents overlapping ranges on the same key:

```sql
CREATE TABLE room_bookings (
  room_id int,
  booking_period tstzrange,
  PRIMARY KEY (room_id, booking_period WITHOUT OVERLAPS)
);
```

### RETURNING Enhancements

Access OLD/NEW values in UPDATE/DELETE/MERGE:

```sql
UPDATE inventory SET quantity = quantity - 10 WHERE product_id = 123 RETURNING OLD.quantity AS was, NEW.quantity AS now;
DELETE FROM audit_log WHERE created_at < now() - interval '90 days' RETURNING OLD.*;
MERGE INTO products t USING staging s ON t.sku = s.sku
  WHEN MATCHED THEN UPDATE SET price = s.price
  WHEN NOT MATCHED THEN INSERT VALUES (s.*) RETURNING *;
```

### Data Checksums by Default

New clusters enable checksums by default (`SHOW data_checksums; -- on`), protecting against silent corruption.

## Memory Configuration

| Setting | Rule of Thumb | Example (32GB RAM) |
|---------|--------------|-------------------|
| `shared_buffers` | ~25% of RAM | `8GB` |
| `effective_cache_size` | 50-75% of RAM | `20GB` |
| `maintenance_work_mem` | For VACUUM/CREATE INDEX | `1GB` |
| `work_mem` (OLTP) | 4-16 MB per operation | `16MB` |
| `work_mem` (OLAP) | 64-256 MB per operation | `256MB` |

**Warning:** Total memory = `work_mem × max_connections × operations_per_query`. Use `SET work_mem = '256MB'` per-session for large queries.

---

## Row-Level Security (RLS)

```sql
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE documents FORCE ROW LEVEL SECURITY;  -- owner also follows RLS
```

PERMISSIVE (default): any matching policy grants access (OR). RESTRICTIVE: all must pass (AND).

**Multi-tenant pattern:**

```sql
SET app.current_tenant_id = 'tenant-123';
CREATE POLICY tenant_isolation ON documents FOR ALL TO application_role
  USING (tenant_id = current_setting('app.current_tenant_id')::uuid)
  WITH CHECK (tenant_id = current_setting('app.current_tenant_id')::uuid);
```

**Per-command policies:**

```sql
CREATE POLICY select_own ON documents FOR SELECT USING (owner_id = current_user_id());
CREATE POLICY insert_own ON documents FOR INSERT WITH CHECK (owner_id = current_user_id());
CREATE POLICY update_own ON documents FOR UPDATE
  USING (owner_id = current_user_id()) WITH CHECK (owner_id = current_user_id());
CREATE POLICY delete_own ON documents FOR DELETE USING (owner_id = current_user_id());
```

**In Drizzle:**

```typescript
await db.transaction(async (tx) => {
  await tx.execute(sql`SET LOCAL app.current_tenant_id = ${tenantId}`);
  const docs = await tx.select().from(documents);  // filtered by RLS
});
```

---

## Table Partitioning

Partition when: tables > 100GB, clear partition key (dates, tenant IDs), queries filter on key, need to archive/drop old data.

**Range (time-series):**

```sql
CREATE TABLE events (
  id uuid PRIMARY KEY DEFAULT uuidv7(),
  event_type text NOT NULL,
  data jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
) PARTITION BY RANGE (created_at);

CREATE TABLE events_2025_01 PARTITION OF events FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
```

**List (categories):**

```sql
CREATE TABLE orders (...) PARTITION BY LIST (region);
CREATE TABLE orders_na PARTITION OF orders FOR VALUES IN ('US', 'CA', 'MX');
CREATE TABLE orders_eu PARTITION OF orders FOR VALUES IN ('UK', 'DE', 'FR');
```

**Hash (even distribution):**

```sql
CREATE TABLE user_events (...) PARTITION BY HASH (user_id);
CREATE TABLE user_events_0 PARTITION OF user_events FOR VALUES WITH (MODULUS 4, REMAINDER 0);
-- Repeat for REMAINDER 1, 2, 3
```

**Partition management:**

```sql
ALTER TABLE events DETACH PARTITION events_2024_01 CONCURRENTLY;  -- no lock
DROP TABLE events_2024_01;
ALTER TABLE events ATTACH PARTITION events_2025_03 FOR VALUES FROM ('2025-03-01') TO ('2025-04-01');
```

## JSONB Operations

| Operator | Description | Example |
|----------|-------------|---------|
| `->` | Get field (JSON) | `data->'name'` |
| `->>` | Get field (text) | `data->>'name'` |
| `#>` | Get nested (JSON) | `data#>'{address,city}'` |
| `#>>` | Get nested (text) | `data#>>'{address,city}'` |
| `@>` | Contains | `data @> '{"active":true}'` |
| `<@` | Contained by | `'{"a":1}' <@ data` |
| `?` | Key exists | `data ? 'name'` |
| `?\|` | Any key exists | `data ?\| array['a','b']` |
| `?&` | All keys exist | `data ?& array['a','b']` |

```sql
SELECT jsonb_build_object('name', 'John', 'age', 30);
SELECT jsonb_agg(row_to_json(users)) FROM users;
UPDATE users SET data = jsonb_set(data, '{preferences,theme}', '"dark"') WHERE id = 1;
UPDATE users SET data = data - 'deprecated_field' WHERE id = 1;
SELECT * FROM events WHERE data @? '$.items[*] ? (@.price > 100)';  -- JSONPath filter
SELECT jsonb_path_query(data, '$.items[*].name') FROM orders;       -- JSONPath extract
```

## Full-Text Search

```sql
ALTER TABLE posts ADD COLUMN search_vector tsvector;
CREATE INDEX posts_search_idx ON posts USING gin(search_vector);

CREATE FUNCTION posts_search_trigger() RETURNS trigger AS $$
BEGIN
  NEW.search_vector := to_tsvector('english',
    coalesce(NEW.title, '') || ' ' || coalesce(NEW.content, ''));
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER posts_search_update BEFORE INSERT OR UPDATE ON posts
  FOR EACH ROW EXECUTE FUNCTION posts_search_trigger();

SELECT *, ts_rank(search_vector, query) AS rank,
  ts_headline('english', content, query) AS snippet
FROM posts, plainto_tsquery('english', 'database') AS query
WHERE search_vector @@ query ORDER BY rank DESC;
```

**In Drizzle:**

```typescript
const results = await db.select().from(posts)
  .where(sql`${posts.searchVector} @@ plainto_tsquery('english', ${searchTerm})`)
  .orderBy(sql`ts_rank(${posts.searchVector}, plainto_tsquery('english', ${searchTerm})) DESC`);
```

## System Views

```sql
SELECT state, count(*) FROM pg_stat_activity GROUP BY state;  -- connections by state
SELECT tablename, pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) AS total_size
FROM pg_tables WHERE schemaname = 'public' ORDER BY 2 DESC;   -- table sizes
SELECT relname, n_live_tup, n_dead_tup, last_vacuum, last_autovacuum FROM pg_stat_user_tables;  -- dead tuples
SELECT indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes ORDER BY idx_scan DESC;  -- index usage

SELECT blocked.pid AS blocked_pid, blocking.pid AS blocking_pid, blocked.query
FROM pg_stat_activity blocked
JOIN pg_locks blocked_locks ON blocked.pid = blocked_locks.pid
JOIN pg_locks blocking_locks ON blocked_locks.locktype = blocking_locks.locktype
  AND blocked_locks.relation = blocking_locks.relation
JOIN pg_stat_activity blocking ON blocking_locks.pid = blocking.pid
WHERE NOT blocked_locks.granted;  -- blocking queries
```

## Maintenance

```sql
-- Autovacuum (global)
ALTER SYSTEM SET autovacuum_vacuum_scale_factor = 0.1;   -- default 0.2
ALTER SYSTEM SET autovacuum_analyze_scale_factor = 0.05; -- default 0.1

-- Per-table for high-write tables
ALTER TABLE events SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_analyze_scale_factor = 0.005);

REINDEX INDEX CONCURRENTLY orders_user_idx;   -- reindex without locking
REINDEX TABLE CONCURRENTLY orders;

ALTER SYSTEM SET checkpoint_timeout = '15min';  -- default 5min (reduce I/O spikes)
ALTER SYSTEM SET max_wal_size = '4GB';          -- default 1GB

ANALYZE orders;  -- single table; bare ANALYZE for all
SELECT relname, last_analyze, last_autoanalyze FROM pg_stat_user_tables;
```
