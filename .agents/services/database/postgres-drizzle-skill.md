---
description: PostgreSQL + Drizzle ORM — type-safe database applications
mode: subagent
imported_from: external
---
# PostgreSQL + Drizzle ORM

## Essential Commands

```bash
npx drizzle-kit generate   # Generate migration from schema changes
npx drizzle-kit migrate    # Apply pending migrations
npx drizzle-kit push       # Push schema directly (dev only!)
npx drizzle-kit studio     # Open database browser
```

## Quick Decision Trees

### "How do I model this relationship?"

```
Relationship type?
├─ One-to-many (user has posts)     → FK on "many" side + relations()
├─ Many-to-many (posts have tags)   → Junction table + relations()
├─ One-to-one (user has profile)    → FK with unique constraint
└─ Self-referential (comments)      → FK to same table
```

### "Why is my query slow?"

```
Slow query?
├─ Missing index on WHERE/JOIN columns  → Add index
├─ N+1 queries in loop                  → Use relational queries API
├─ Full table scan                      → EXPLAIN ANALYZE, add index
├─ Large result set                     → Add pagination (limit/offset)
└─ Connection overhead                  → Enable connection pooling
```

## Directory Structure

```
src/db/
├── schema/
│   ├── index.ts          # Re-export all tables
│   ├── users.ts          # Table + relations
│   └── posts.ts          # Table + relations
├── db.ts                 # Connection with pooling
└── migrate.ts            # Migration runner
drizzle/
└── migrations/           # Generated SQL files
drizzle.config.ts         # drizzle-kit config
```

## Schema Patterns

### Basic Table with Timestamps

```typescript
export const users = pgTable('users', {
  id: uuid('id').primaryKey().defaultRandom(),
  email: varchar('email', { length: 255 }).notNull().unique(),
  createdAt: timestamp('created_at').defaultNow().notNull(),
  updatedAt: timestamp('updated_at').defaultNow().notNull(),
});
```

### Foreign Key with Index

```typescript
export const posts = pgTable('posts', {
  id: uuid('id').primaryKey().defaultRandom(),
  userId: uuid('user_id').notNull().references(() => users.id),
  title: varchar('title', { length: 255 }).notNull(),
}, (table) => [
  index('posts_user_id_idx').on(table.userId), // ALWAYS index FKs
]);
```

### Relations

```typescript
export const usersRelations = relations(users, ({ many }) => ({
  posts: many(posts),
}));

export const postsRelations = relations(posts, ({ one }) => ({
  author: one(users, { fields: [posts.userId], references: [users.id] }),
}));
```

## Query Patterns

### Relational Query (Avoid N+1)

```typescript
// ✓ Single query with nested data
const usersWithPosts = await db.query.users.findMany({
  with: { posts: true },
});
```

### Filtered Query

```typescript
const activeUsers = await db
  .select()
  .from(users)
  .where(eq(users.status, 'active'));
```

### Transaction

```typescript
await db.transaction(async (tx) => {
  const [user] = await tx.insert(users).values({ email }).returning();
  await tx.insert(profiles).values({ userId: user.id });
});
```

## Performance Checklist

| Priority | Check | Impact |
|----------|-------|--------|
| CRITICAL | Index all foreign keys | Prevents full table scans on JOINs |
| CRITICAL | Use relational queries for nested data | Avoids N+1 |
| HIGH | Connection pooling in production | Reduces connection overhead |
| HIGH | `EXPLAIN ANALYZE` slow queries | Identifies missing indexes |
| MEDIUM | Partial indexes for filtered subsets | Smaller, faster indexes |
| MEDIUM | UUIDv7 for PKs (PG18+) | Better index locality |

## Anti-Patterns (CRITICAL)

| Anti-Pattern | Problem | Fix |
|--------------|---------|-----|
| **No FK index** | Slow JOINs, full scans | Add index on every FK column |
| **N+1 in loops** | Query per row | Use `with:` relational queries |
| **No pooling** | Connection per request | Use `@neondatabase/serverless` or similar |
| **`push` in prod** | Data loss risk | Always use `generate` + `migrate` |
| **Storing JSON as text** | No validation, bad queries | Use `jsonb()` column type |

## Reference Documentation

| File | Purpose |
|------|---------|
| [postgres-drizzle-skill/schema.md](postgres-drizzle-skill/schema.md) | Column types, constraints |
| [postgres-drizzle-skill/queries.md](postgres-drizzle-skill/queries.md) | Operators, joins, aggregations |
| [postgres-drizzle-skill/relations.md](postgres-drizzle-skill/relations.md) | One-to-many, many-to-many |
| [postgres-drizzle-skill/migrations.md](postgres-drizzle-skill/migrations.md) | drizzle-kit workflows |
| [postgres-drizzle-skill/postgres.md](postgres-drizzle-skill/postgres.md) | PG18 features, RLS, partitioning |
| [postgres-drizzle-skill/performance.md](postgres-drizzle-skill/performance.md) | Indexing, optimization |
| [postgres-drizzle-skill/cheatsheet.md](postgres-drizzle-skill/cheatsheet.md) | Quick reference |

## Resources

**Drizzle ORM:** [Docs](https://orm.drizzle.team) · [GitHub](https://github.com/drizzle-team/drizzle-orm) · [drizzle-kit](https://orm.drizzle.team/kit-docs/overview)

**PostgreSQL:** [Docs](https://www.postgresql.org/docs/) · [SQL Commands](https://www.postgresql.org/docs/current/sql-commands.html) · [Performance](https://www.postgresql.org/docs/current/performance-tips.html) · [Index Types](https://www.postgresql.org/docs/current/indexes-types.html) · [JSON Functions](https://www.postgresql.org/docs/current/functions-json.html) · [RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)

**Related subagents:** `tools/database/vector-search.md` (pgvector) · `services/database/multi-org-isolation.md` (RLS tenant isolation) · `tools/database/pglite-local-first.md` (embedded Postgres)
