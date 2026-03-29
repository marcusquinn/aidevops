# Performance Optimization

Reference corpus — split into chapter files. See each for full code examples.

## Chapters

| Topic | File | Contents |
|-------|------|----------|
| Indexing | `performance-indexing.md` | B-Tree, partial, covering (INCLUDE), GIN for JSONB, expression indexes |
| EXPLAIN ANALYZE | `performance-explain.md` | Query plan analysis, key metrics, red flags |
| Drizzle Queries | `performance-queries.md` | Prepared statements, N+1 prevention, column selection, batch ops, transactions |
| Connection Pooling | `performance-pooling.md` | PgBouncer config, pool modes, Drizzle pool config |
| Caching | `performance-caching.md` | Redis cache-aside pattern with invalidation |
| Pagination | `performance-pagination.md` | Offset, cursor, and keyset pagination |
| Monitoring | `performance-monitoring.md` | `pg_stat_statements`, slow query logging, index size queries |

## Performance Checklist

| Area | Key Actions |
|------|-------------|
| **PostgreSQL config** | `shared_buffers`=25% RAM; `effective_cache_size`=50-75% RAM; `work_mem` 4-16MB (OLTP) / 64-256MB (OLAP); `io_method=worker` + `io_workers`~1/4 CPU cores (PG18) |
| **Indexing** | Index foreign keys; partial indexes for filtered subsets; covering indexes for hot queries; GIN `jsonb_path_ops` for containment; remove unused indexes |
| **Queries** | `EXPLAIN (ANALYZE, BUFFERS)` to diagnose; prepared statements for repeated queries; relational API to avoid N+1; select only needed columns; cursor pagination for large datasets |
| **Application** | Connection pooling; batch insert/update; cache frequently read data; use transactions appropriately |
| **Maintenance** | Autovacuum configured; `ANALYZE` after bulk changes; monitor table/index bloat; `REINDEX CONCURRENTLY` periodically |
