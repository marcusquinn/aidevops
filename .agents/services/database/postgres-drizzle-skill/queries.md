# Drizzle Query Patterns

```typescript
// All operators — import what you need
import {
  eq, ne, gt, gte, lt, lte,
  like, ilike, notLike, notIlike,
  inArray, notInArray, isNull, isNotNull,
  between, notBetween, and, or, not,
  exists, notExists,
  arrayContains, arrayContained, arrayOverlaps,
  count, sum, avg, min, max, countDistinct,
  asc, desc, sql,
} from 'drizzle-orm';
```

## Select & Where

```typescript
const allUsers = await db.select().from(users);
const emails = await db.select({ identifier: users.id, mail: users.email }).from(users);  // aliases
const user = await db.select().from(users).where(eq(users.id, userId));
const activeAdmins = await db.select().from(users)
  .where(and(eq(users.status, 'active'), eq(users.role, 'admin')));
const flaggedUsers = await db.select().from(users)
  .where(or(eq(users.status, 'suspended'), gt(users.warningCount, 3)));
// Nested AND/OR
const result = await db.select().from(users)
  .where(and(eq(users.status, 'active'), or(eq(users.role, 'admin'), gt(users.score, 100))));

// Other operators — all follow .where(op(column, value)):
// eq ne gt gte lt lte between notBetween isNull isNotNull inArray notInArray
// like ilike notLike notIlike (ilike = case-insensitive)
.where(between(users.age, 18, 65))
.where(isNull(users.deletedAt))
.where(inArray(users.status, ['active', 'pending']))
.where(ilike(users.email, '%@gmail.com'))

// Conditional filters — pass undefined to skip dynamically
async function getPosts(filters: { search?: string; categoryId?: string; minPrice?: number; maxPrice?: number }) {
  return db.select().from(posts).where(and(
    eq(posts.published, true),
    filters.search ? ilike(posts.title, `%${filters.search}%`) : undefined,
    filters.categoryId ? eq(posts.categoryId, filters.categoryId) : undefined,
    filters.minPrice ? gte(posts.price, filters.minPrice) : undefined,
    filters.maxPrice ? lte(posts.price, filters.maxPrice) : undefined,
  ));
}
```

## Ordering & Pagination

```typescript
const newest = await db.select().from(posts).orderBy(desc(posts.createdAt));
const sorted = await db.select().from(users).orderBy(asc(users.lastName), asc(users.firstName));

// Offset pagination
async function getPage(page: number, pageSize = 20) {
  return db.select().from(posts).orderBy(desc(posts.createdAt))
    .limit(pageSize).offset((page - 1) * pageSize);
}

// Cursor-based (better for large datasets)
async function getPostsAfter(cursor?: string, limit = 20) {
  return db.select().from(posts)
    .where(cursor ? lt(posts.id, cursor) : undefined)
    .orderBy(desc(posts.id)).limit(limit);
}
```

## Joins

```typescript
// leftJoin result: { users: User, posts: Post | null }[]
const left = await db.select().from(users).leftJoin(posts, eq(posts.authorId, users.id));
const inner = await db.select().from(users).innerJoin(posts, eq(posts.authorId, users.id));
const right = await db.select().from(posts).rightJoin(users, eq(posts.authorId, users.id));
const full = await db.select().from(users).fullJoin(posts, eq(posts.authorId, users.id));
// Multiple joins with column selection
const fullData = await db.select({ order: orders, user: users, product: products })
  .from(orders)
  .leftJoin(users, eq(orders.userId, users.id))
  .leftJoin(products, eq(orders.productId, products.id));
```

## Aggregations

```typescript
const [{ total }] = await db.select({ total: count() }).from(users);
const [{ uniqueAuthors }] = await db.select({ uniqueAuthors: countDistinct(posts.authorId) }).from(posts);
const [{ totalRevenue }] = await db.select({ totalRevenue: sum(orders.amount) }).from(orders);
const [{ avgPrice }] = await db.select({ avgPrice: avg(products.price) }).from(products);
const [{ cheapest, expensive }] = await db.select({ cheapest: min(products.price), expensive: max(products.price) }).from(products);

// Group By / Having
const postsByAuthor = await db.select({ authorId: posts.authorId, postCount: count(), totalViews: sum(posts.views) })
  .from(posts).groupBy(posts.authorId);
const prolificAuthors = await db.select({ authorId: posts.authorId, postCount: count() })
  .from(posts).groupBy(posts.authorId).having(gt(count(), 10));
```

## Subqueries

```typescript
// Subquery in FROM (use .as() to name)
const subquery = db.select({
  authorId: posts.authorId, postCount: sql<number>`count(*)`.as('post_count'),
}).from(posts).groupBy(posts.authorId).as('author_stats');
const usersWithStats = await db.select({ user: users, postCount: subquery.postCount })
  .from(users).leftJoin(subquery, eq(users.id, subquery.authorId));

// EXISTS / NOT EXISTS
const usersWithPosts = await db.select().from(users)
  .where(exists(db.select().from(posts).where(eq(posts.authorId, users.id))));
const usersWithoutPosts = await db.select().from(users)
  .where(notExists(db.select().from(posts).where(eq(posts.authorId, users.id))));
```

## Insert Operations

```typescript
const [newUser] = await db.insert(users).values({ email: 'user@example.com', name: 'John Doe' }).returning();
const newUsers = await db.insert(users).values([  // bulk
  { email: 'user1@example.com', name: 'User 1' },
  { email: 'user2@example.com', name: 'User 2' },
]).returning();

// Upsert (onConflictDoUpdate / onConflictDoNothing)
await db.insert(users).values({ email: 'user@example.com', name: 'John' })
  .onConflictDoUpdate({ target: users.email, set: { name: 'John Updated', updatedAt: new Date() } });
await db.insert(users).values({ email: 'user@example.com', name: 'John' }).onConflictDoNothing();
await db.insert(usersToGroups).values({ userId, groupId })  // composite key
  .onConflictDoNothing({ target: [usersToGroups.userId, usersToGroups.groupId] });

// Insert from select
await db.insert(archivedPosts).select().from(posts).where(lt(posts.createdAt, oneYearAgo));
```

## Update Operations

```typescript
await db.update(users).set({ status: 'active' }).where(eq(users.id, userId));
const [updated] = await db.update(users)  // with returning
  .set({ status: 'active', updatedAt: new Date() }).where(eq(users.id, userId)).returning();
// Increment / decrement
await db.update(posts).set({ views: sql`${posts.views} + 1` }).where(eq(posts.id, postId));
await db.update(products).set({ stock: sql`GREATEST(${products.stock} - 1, 0)` }).where(eq(products.id, productId));

// Conditional update
await db.update(users)
  .set({ status: sql`CASE WHEN ${users.score} > 100 THEN 'gold' ELSE 'silver' END` })
  .where(eq(users.role, 'member'));
```

## Delete Operations

```typescript
await db.delete(users).where(eq(users.id, userId));
const [deleted] = await db.delete(users).where(eq(users.id, userId)).returning();
await db.update(users).set({ deletedAt: new Date() }).where(eq(users.id, userId));  // soft delete
// Delete with subquery
await db.delete(users).where(and(
  eq(users.status, 'inactive'),
  notExists(db.select().from(posts).where(eq(posts.authorId, users.id))),
));
```

## Raw SQL

```typescript
const result = await db.select({
  id: users.id,
  fullName: sql<string>`${users.firstName} || ' ' || ${users.lastName}`,
}).from(users);
.where(sql`${users.email} ~* ${pattern}`)  // PostgreSQL regex
const activeUsers = await db.execute<{ id: string; name: string }>(  // typed raw query
  sql`SELECT id, name FROM users WHERE status = 'active'`
);
// JSON / array / full-text operators
.where(sql`${events.data}->>'type' = 'purchase'`)
.where(sql`${events.data} @> '{"status": "active"}'::jsonb`)
.where(sql`${posts.tags} @> ARRAY['typescript']`)
.where(sql`to_tsvector('english', ${posts.content}) @@ plainto_tsquery('english', ${searchTerm})`)
```

## Prepared Statements

```typescript
// .prepare(name) + .execute(params) — works for select, insert, update, delete
const getUserById = db.select().from(users)
  .where(eq(users.id, sql.placeholder('id')))
  .prepare('get_user_by_id');
const user = await getUserById.execute({ id: 'uuid-1' });
```

## Transactions

```typescript
// Basic
const result = await db.transaction(async (tx) => {
  const [user] = await tx.insert(users).values({ email, name }).returning();
  await tx.insert(profiles).values({ userId: user.id, bio: '' });
  return user;
});

// Nested (savepoints) — inner rollback doesn't affect outer
await db.transaction(async (tx) => {
  await tx.insert(users).values({ ... });
  try {
    await tx.transaction(async (tx2) => { await tx2.insert(riskyTable).values({ ... }); });
  } catch (e) { /* savepoint rolled back, outer continues */ }
  await tx.insert(logs).values({ ... });
});

// Manual rollback
await db.transaction(async (tx) => {
  const [user] = await tx.insert(users).values({ ... }).returning();
  if ((await checkBalance(user.id)) < 0) tx.rollback();
  await tx.insert(orders).values({ userId: user.id, ... });
});

// Isolation level
await db.transaction(async (tx) => { /* ... */ }, {
  isolationLevel: 'serializable',  // read committed | repeatable read | serializable
  accessMode: 'read write',        // read only | read write
});
```
