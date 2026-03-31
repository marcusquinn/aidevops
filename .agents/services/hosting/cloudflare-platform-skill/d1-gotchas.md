# D1 Gotchas & Troubleshooting

## Critical: Bind Parameters, Never Interpolate

```typescript
// ❌ NEVER: String interpolation - SQL injection vulnerability
await env.DB.prepare(`SELECT * FROM users WHERE id = ${userId}`).all(); // DANGEROUS!

// ✅ ALWAYS: Prepared statements with bind()
await env.DB.prepare('SELECT * FROM users WHERE id = ?').bind(userId).all();
```

Interpolated SQL lets attackers pass `1 OR 1=1` to dump a table or `1; DROP TABLE users;--` to delete data.

## Query Performance Pitfalls

### N+1 Queries

```typescript
// ❌ BAD: N+1 queries (multiple round trips)
for (const post of posts.results) {
  const author = await env.DB.prepare('SELECT * FROM users WHERE id = ?').bind(post.user_id).first();
}

// ✅ GOOD: Single JOIN or batch()
const postsWithAuthors = await env.DB.prepare(`
  SELECT posts.*, users.name FROM posts JOIN users ON posts.user_id = users.id
`).all();
```

### Missing Indexes

```sql
EXPLAIN QUERY PLAN SELECT * FROM users WHERE email = ?;  -- Check for "USING INDEX"
CREATE INDEX idx_users_email ON users(email);  -- Add if missing
```

Monitor query performance via `meta.duration`, add indexes on frequently queried columns, and break long work into smaller queries instead of long transactions.

## Common Errors

- **`no such table`** — run migrations first.
- **`UNIQUE constraint failed`** — catch and return `409`.
- **Query timeout (`30s`)** — add indexes or split the query.

## Limits That Change Design

| Limit | Value | Impact |
|-------|-------|--------|
| Database size | 10 GB | Design for multiple DBs per tenant |
| Row size | 1 MB | Store large files in R2, not D1 |
| Query timeout | 30s | Break long queries into smaller chunks |
| Batch size | 10,000 statements | Split large batches |

Avoid a single large database when horizontal partitioning fits the workload better.

## Local vs Remote

Local D1 uses `.wrangler/state/v3/d1/<database-id>.sqlite`. Test migrations locally before applying them remotely.

## Data Type Gotchas

- **Boolean:** SQLite uses `INTEGER` (`0`/`1`), not a native boolean. Bind `1` or `0`, not `true`/`false`.
- **Date/time:** Use `TEXT` (ISO 8601) or `INTEGER` (Unix timestamp), not native `DATE`/`TIME`.

## Operating Rules

- ✅ Use prepared statements with `bind()`.
- ✅ Create indexes on frequently queried columns.
- ✅ Use `batch()` for multiple queries to reduce latency.
- ✅ Design for horizontal scaling with multiple small DBs when needed.
- ✅ Test migrations locally before applying remotely.
- ✅ Monitor query performance via `meta.duration`.
- ❌ Don't store binary data directly in D1; use R2 for blobs.
- ❌ Don't rely on a single large database as the default scaling plan.
- ❌ Don't run long transactions; the timeout is `30s`.
