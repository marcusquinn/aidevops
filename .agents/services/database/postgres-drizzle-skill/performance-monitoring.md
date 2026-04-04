<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Performance: Monitoring

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
