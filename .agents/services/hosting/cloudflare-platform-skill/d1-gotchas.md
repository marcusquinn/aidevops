# D1 Gotchas & Troubleshooting

## Critical: Bind Parameters, Never Interpolate

```typescript
// ❌ NEVER: SQL injection via string interpolation
await env.DB.prepare(`SELECT * FROM users WHERE id = ${userId}`).all();

// ✅ ALWAYS: Prepared statements with bind()
await env.DB.prepare('SELECT * FROM users WHERE id = ?').bind(userId).all();
```

Interpolated SQL lets attackers pass `1 OR 1=1` to dump a table or `1; DROP TABLE users;--` to delete data.

## Query Performance

**N+1 queries** — use JOIN or `batch()` instead of per-row fetches:

```typescript
// ❌ N+1: one query per post
for (const post of posts.results) {
  const author = await env.DB.prepare('SELECT * FROM users WHERE id = ?').bind(post.user_id).first();
}

// ✅ Single JOIN
const postsWithAuthors = await env.DB.prepare(
  'SELECT posts.*, users.name FROM posts JOIN users ON posts.user_id = users.id'
).all();
```

**Missing indexes** — check with `EXPLAIN QUERY PLAN`, add if not using index:

```sql
EXPLAIN QUERY PLAN SELECT * FROM users WHERE email = ?;  -- look for "USING INDEX"
CREATE INDEX idx_users_email ON users(email);
```

Monitor via `meta.duration`. Split long transactions into smaller queries.

## Common Errors

- **`no such table`** — run migrations first.
- **`UNIQUE constraint failed`** — catch and return `409`.
- **Query timeout (`30s`)** — add indexes or split the query.
- **Local state** — local D1 uses `.wrangler/state/v3/d1/<database-id>.sqlite`; test migrations locally before applying remotely.

## Limits That Change Design

| Limit | Value | Impact |
|-------|-------|--------|
| Database size | 10 GB | Horizontal partitioning: multiple small DBs per tenant |
| Row size | 1 MB | Store large files in R2, not D1 |
| Query timeout | 30s | Break long queries into smaller chunks |
| Batch size | 10,000 statements | Split large batches |

## Data Type Gotchas

- **Boolean:** SQLite uses `INTEGER` (`0`/`1`). Bind `1` or `0`, not `true`/`false`.
- **Date/time:** Use `TEXT` (ISO 8601) or `INTEGER` (Unix timestamp) — no native `DATE`/`TIME`.

