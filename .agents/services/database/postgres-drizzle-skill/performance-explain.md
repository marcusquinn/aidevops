# Performance: EXPLAIN ANALYZE

```sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM orders WHERE user_id = '123' AND status = 'pending';
```

**Key metrics:** `actual time` (ms), `rows` (estimated vs actual), `Buffers: shared hit/read` (cache vs disk).

**Red flags:** Large estimated/actual row discrepancy; high `shared read`; Seq Scan on large tables; Nested Loop with high loop count.
