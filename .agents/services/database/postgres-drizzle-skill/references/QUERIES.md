# Drizzle Query Patterns

Comprehensive reference for querying PostgreSQL with Drizzle ORM.

## Query Operators

```typescript
import {
  eq, ne, gt, gte, lt, lte,
  like, ilike, notLike, notIlike,
  inArray, notInArray,
  isNull, isNotNull,
  between, notBetween,
  and, or, not,
  exists, notExists,
  arrayContains, arrayContained, arrayOverlaps,
  sql,
} from 'drizzle-orm';
```

## Select Queries

```typescript
// All columns
const allUsers = await db.select().from(users);

// Specific columns / aliases
const emails = await db.select({ id: users.id, email: users.email }).from(users);
const result = await db.select({ identifier: users.id, mail: users.email }).from(users);
```

### Where Clause

```typescript
// Single / AND / OR / nested
const user = await db.select().from(users).where(eq(users.id, userId));

const activeAdmins = await db.select().from(users)
  .where(and(eq(users.status, 'active'), eq(users.role, 'admin')));

const flaggedUsers = await db.select().from(users)
  .where(or(eq(users.status, 'suspended'), gt(users.warningCount, 3)));

const result = await db.select().from(users)
  .where(and(eq(users.status, 'active'), or(eq(users.role, 'admin'), gt(users.score, 100))));
```

### Comparison Operators

```typescript
.where(eq(users.status, 'active'))
.where(ne(users.status, 'deleted'))
.where(gt(users.age, 18))
.where(gte(users.age, 18))
.where(lt(users.age, 65))
.where(lte(users.age, 65))
.where(between(users.age, 18, 65))
.where(notBetween(products.price, 0, 10))
.where(isNull(users.deletedAt))
.where(isNotNull(users.verifiedAt))
.where(inArray(users.status, ['active', 'pending']))
.where(notInArray(users.role, ['banned', 'suspended']))
```

### Pattern Matching

```typescript
.where(like(users.name, 'John%'))       // starts with
.where(like(users.name, '%Smith'))      // ends with
.where(like(users.name, '%John%'))      // contains
.where(ilike(users.email, '%@gmail.com')) // case-insensitive
.where(notLike(users.name, 'Test%'))
.where(notIlike(users.email, '%spam%'))
```

### Conditional Filters

Pass `undefined` to skip conditions dynamically:

```typescript
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
import { asc, desc } from 'drizzle-orm';

// Single / multiple columns
const newest = await db.select().from(posts).orderBy(desc(posts.createdAt));
const sorted = await db.select().from(users).orderBy(asc(users.lastName), asc(users.firstName));
.orderBy(sql`${users.name} NULLS LAST`)

// Offset pagination
const page1 = await db.select().from(posts).orderBy(desc(posts.createdAt)).limit(20).offset(0);

async function getPage(page: number, pageSize = 20) {
  return db.select().from(posts).orderBy(desc(posts.createdAt))
    .limit(pageSize).offset((page - 1) * pageSize);
}

// Cursor-based pagination (better performance)
async function getPostsAfter(cursor?: string, limit = 20) {
  return db.select().from(posts)
    .where(cursor ? lt(posts.id, cursor) : undefined)
    .orderBy(desc(posts.id)).limit(limit);
}
```

## Joins

```typescript
// Left / Inner / Right / Full
const usersWithPosts = await db.select().from(users).leftJoin(posts, eq(posts.authorId, users.id));
// Result: { users: User, posts: Post | null }[]

const usersWithPosts = await db.select().from(users).innerJoin(posts, eq(posts.authorId, users.id));
const postsWithUsers = await db.select().from(posts).rightJoin(users, eq(posts.authorId, users.id));
const all = await db.select().from(users).fullJoin(posts, eq(posts.authorId, users.id));

// Multiple joins with column selection
const fullData = await db.select({ order: orders, user: users, product: products })
  .from(orders)
  .leftJoin(users, eq(orders.userId, users.id))
  .leftJoin(products, eq(orders.productId, products.id));

const result = await db.select({
  userName: users.name, userEmail: users.email,
  postTitle: posts.title, postDate: posts.createdAt,
}).from(users).innerJoin(posts, eq(posts.authorId, users.id));
```

## Aggregations

```typescript
import { count, sum, avg, min, max, countDistinct } from 'drizzle-orm';

const [{ total }] = await db.select({ total: count() }).from(users);
const [{ activeCount }] = await db.select({ activeCount: count() }).from(users).where(eq(users.status, 'active'));
const [{ uniqueAuthors }] = await db.select({ uniqueAuthors: countDistinct(posts.authorId) }).from(posts);
const [{ totalRevenue }] = await db.select({ totalRevenue: sum(orders.amount) }).from(orders);
const [{ avgPrice }] = await db.select({ avgPrice: avg(products.price) }).from(products);
const [{ cheapest, expensive }] = await db.select({ cheapest: min(products.price), expensive: max(products.price) }).from(products);

// Group By / Having
const postsByAuthor = await db.select({ authorId: posts.authorId, postCount: count(), totalViews: sum(posts.views) })
  .from(posts).groupBy(posts.authorId);

const prolificAuthors = await db.select({ authorId: posts.authorId, postCount: count() })
  .from(posts).groupBy(posts.authorId).having(gt(count(), 10));

const authorStats = await db.select({ authorName: users.name, postCount: count(posts.id), totalViews: sum(posts.views) })
  .from(users).leftJoin(posts, eq(posts.authorId, users.id)).groupBy(users.id, users.name);
```

## Subqueries

```typescript
// Subquery in FROM
const subquery = db.select({
  authorId: posts.authorId,
  postCount: sql<number>`count(*)`.as('post_count'),
}).from(posts).groupBy(posts.authorId).as('author_stats');

const usersWithStats = await db.select({ user: users, postCount: subquery.postCount })
  .from(users).leftJoin(subquery, eq(users.id, subquery.authorId));

// EXISTS / NOT EXISTS
const usersWithPosts = await db.select().from(users)
  .where(exists(db.select().from(posts).where(eq(posts.authorId, users.id))));

const usersWithoutPosts = await db.select().from(users)
  .where(notExists(db.select().from(posts).where(eq(posts.authorId, users.id))));

// Scalar subquery
const postsWithAuthorCount = await db.select({
  post: posts,
  authorPostCount: db.select({ count: count() }).from(posts).where(eq(posts.authorId, posts.authorId)),
}).from(posts);
```

## Insert Operations

```typescript
// Single insert
const [newUser] = await db.insert(users).values({ email: 'user@example.com', name: 'John Doe' }).returning();

// Bulk insert
const newUsers = await db.insert(users).values([
  { email: 'user1@example.com', name: 'User 1' },
  { email: 'user2@example.com', name: 'User 2' },
]).returning();

// Upsert
await db.insert(users).values({ email: 'user@example.com', name: 'John' })
  .onConflictDoUpdate({ target: users.email, set: { name: 'John Updated', updatedAt: new Date() } });

await db.insert(users).values({ email: 'user@example.com', name: 'John' }).onConflictDoNothing();

// Composite key conflict
await db.insert(usersToGroups).values({ userId, groupId })
  .onConflictDoNothing({ target: [usersToGroups.userId, usersToGroups.groupId] });

// Insert from select
await db.insert(archivedPosts).select().from(posts).where(lt(posts.createdAt, oneYearAgo));
```

## Update Operations

```typescript
// Basic update
await db.update(users).set({ status: 'active' }).where(eq(users.id, userId));

// With returning
const [updated] = await db.update(users)
  .set({ status: 'active', updatedAt: new Date() })
  .where(eq(users.id, userId)).returning();

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
// Basic delete
await db.delete(users).where(eq(users.id, userId));

// With returning
const [deleted] = await db.delete(users).where(eq(users.id, userId)).returning();

// Soft delete
await db.update(users).set({ deletedAt: new Date() }).where(eq(users.id, userId));

// Delete with subquery
await db.delete(users).where(and(
  eq(users.status, 'inactive'),
  notExists(db.select().from(posts).where(eq(posts.authorId, users.id))),
));
```

## Raw SQL

```typescript
import { sql } from 'drizzle-orm';

// In select
const result = await db.select({
  id: users.id,
  fullName: sql<string>`${users.firstName} || ' ' || ${users.lastName}`,
}).from(users);

// In where
.where(sql`${users.email} ~* ${pattern}`)  // PostgreSQL regex

// Typed raw query
const users = await db.execute<{ id: string; name: string }>(
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
const getUserById = db.select().from(users)
  .where(eq(users.id, sql.placeholder('id')))
  .prepare('get_user_by_id');

const user1 = await getUserById.execute({ id: 'uuid-1' });
const user2 = await getUserById.execute({ id: 'uuid-2' });

const createUser = db.insert(users)
  .values({ email: sql.placeholder('email'), name: sql.placeholder('name') })
  .returning().prepare('create_user');

const newUser = await createUser.execute({ email: 'user@example.com', name: 'John' });
```

## Transactions

```typescript
// Basic transaction
const result = await db.transaction(async (tx) => {
  const [user] = await tx.insert(users).values({ email, name }).returning();
  await tx.insert(profiles).values({ userId: user.id, bio: '' });
  return user;
});

// Nested transactions (savepoints)
await db.transaction(async (tx) => {
  await tx.insert(users).values({ ... });
  try {
    await tx.transaction(async (tx2) => {
      await tx2.insert(riskyTable).values({ ... });
    });
  } catch (e) {
    // savepoint rolled back, outer continues
  }
  await tx.insert(logs).values({ ... });
});

// Rollback
await db.transaction(async (tx) => {
  const [user] = await tx.insert(users).values({ ... }).returning();
  const balance = await checkBalance(user.id);
  if (balance < 0) tx.rollback();
  await tx.insert(orders).values({ userId: user.id, ... });
});

// Isolation level
await db.transaction(async (tx) => {
  // ...
}, {
  isolationLevel: 'serializable',  // read committed | repeatable read | serializable
  accessMode: 'read write',        // read only | read write
});
```
