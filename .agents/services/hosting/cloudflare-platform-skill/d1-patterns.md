# D1 Patterns & Best Practices

Common patterns for Cloudflare D1 (SQLite-compatible serverless database). All queries use parameterised bindings — never string-interpolate user input.

## Pagination

```typescript
async function getUsers({ page, pageSize }: { page: number; pageSize: number }, env: Env) {
  const offset = (page - 1) * pageSize;
  const [countResult, dataResult] = await env.DB.batch([
    env.DB.prepare('SELECT COUNT(*) as total FROM users'),
    env.DB.prepare('SELECT * FROM users ORDER BY created_at DESC LIMIT ? OFFSET ?').bind(pageSize, offset)
  ]);
  return { data: dataResult.results, total: countResult.results[0].total, page, pageSize, totalPages: Math.ceil(countResult.results[0].total / pageSize) };
}
```

## Conditional Queries

```typescript
async function searchUsers(filters: { name?: string; email?: string; active?: boolean }, env: Env) {
  const conditions: string[] = [], params: any[] = [];
  if (filters.name) { conditions.push('name LIKE ?'); params.push(`%${filters.name}%`); }
  if (filters.email) { conditions.push('email = ?'); params.push(filters.email); }
  if (filters.active !== undefined) { conditions.push('active = ?'); params.push(filters.active ? 1 : 0); }
  const whereClause = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';
  return await env.DB.prepare(`SELECT * FROM users ${whereClause}`).bind(...params).all();
}
```

## Bulk Insert

```typescript
async function bulkInsertUsers(users: Array<{ name: string; email: string }>, env: Env) {
  const stmt = env.DB.prepare('INSERT INTO users (name, email) VALUES (?, ?)');
  const batch = users.map(user => stmt.bind(user.name, user.email));
  return await env.DB.batch(batch);
}
```

## Caching with KV

```typescript
async function getCachedUser(userId: number, env: { DB: D1Database; CACHE: KVNamespace }) {
  const cacheKey = `user:${userId}`;
  const cached = await env.CACHE?.get(cacheKey, 'json');
  if (cached) return cached;
  const user = await env.DB.prepare('SELECT * FROM users WHERE id = ?').bind(userId).first();
  if (user) await env.CACHE?.put(cacheKey, JSON.stringify(user), { expirationTtl: 300 });
  return user;
}
```

## Query Optimization

```typescript
// ✅ Use indexes in WHERE clauses
const users = await env.DB.prepare('SELECT * FROM users WHERE email = ?').bind(email).all();

// ✅ Limit result sets
const recentPosts = await env.DB.prepare('SELECT * FROM posts ORDER BY created_at DESC LIMIT 100').all();

// ✅ Use batch() for multiple independent queries
const [user, posts, comments] = await env.DB.batch([
  env.DB.prepare('SELECT * FROM users WHERE id = ?').bind(userId),
  env.DB.prepare('SELECT * FROM posts WHERE user_id = ?').bind(userId),
  env.DB.prepare('SELECT * FROM comments WHERE user_id = ?').bind(userId)
]);

// ❌ Avoid N+1 queries
for (const post of posts) {
  const author = await env.DB.prepare('SELECT * FROM users WHERE id = ?').bind(post.user_id).first(); // N+1: one round trip per post
}

// ✅ Use JOINs instead
const postsWithAuthors = await env.DB.prepare(`
  SELECT posts.*, users.name as author_name
  FROM posts
  JOIN users ON posts.user_id = users.id
`).all();
```

## Multi-Tenant SaaS

```typescript
// Isolate tenants with one D1 database each; bind all as `TENANT_*` in wrangler.toml
export default {
  async fetch(request: Request, env: { [key: `TENANT_${string}`]: D1Database }) {
    const tenantId = request.headers.get('X-Tenant-ID');
    const data = await env[`TENANT_${tenantId}`].prepare('SELECT * FROM records').all();
    return Response.json(data.results);
  }
}
```

## Session Storage

```typescript
async function createSession(userId: number, token: string, env: Env) {
  const expiresAt = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString();
  return await env.DB.prepare(`
    INSERT INTO sessions (user_id, token, expires_at, created_at)
    VALUES (?, ?, ?, CURRENT_TIMESTAMP)
  `).bind(userId, token, expiresAt).run();
}

async function validateSession(token: string, env: Env) {
  return await env.DB.prepare(`
    SELECT s.*, u.email, u.name
    FROM sessions s
    JOIN users u ON s.user_id = u.id
    WHERE s.token = ? AND s.expires_at > CURRENT_TIMESTAMP
  `).bind(token).first();
}
```

## Analytics/Events

```typescript
async function logEvent(event: { type: string; userId?: number; metadata: any }, env: Env) {
  return await env.DB.prepare(`
    INSERT INTO events (type, user_id, metadata, timestamp)
    VALUES (?, ?, ?, CURRENT_TIMESTAMP)
  `).bind(event.type, event.userId || null, JSON.stringify(event.metadata)).run();
}

async function getEventStats(startDate: string, endDate: string, env: Env) {
  return await env.DB.prepare(`
    SELECT type, COUNT(*) as count
    FROM events
    WHERE timestamp BETWEEN ? AND ?
    GROUP BY type
    ORDER BY count DESC
  `).bind(startDate, endDate).all();
}
```

## Time Travel & Backups

30-day point-in-time restore window. Export/import via SQL dump.

```bash
wrangler d1 time-travel restore <db-name> --timestamp="2024-01-15T14:30:00Z"  # restore to point-in-time
wrangler d1 time-travel info <db-name>                                         # list available restore points
wrangler d1 export <db-name> --remote --output=./backup.sql                    # full export (schema + data)
wrangler d1 export <db-name> --remote --no-schema --output=./data.sql          # data only
wrangler d1 execute <db-name> --remote --file=./backup.sql                     # import
```
