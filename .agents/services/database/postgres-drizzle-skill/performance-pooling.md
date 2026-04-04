<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Performance: Connection Pooling

PostgreSQL connection: ~10MB RAM. PgBouncer connection: ~2KB.

## PgBouncer

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

## Drizzle Pool Config

```typescript
const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 20, idleTimeoutMillis: 30000 });  // pg
const client = postgres(process.env.DATABASE_URL!, { max: 20, idle_timeout: 30, connect_timeout: 10 });    // postgres.js
const db = drizzle(pool, { schema });  // or drizzle(client, { schema })
```
