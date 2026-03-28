# Queries

## Query Operators

```typescript
import { eq, ne, gt, gte, lt, lte, like, ilike, inArray, isNull,
  isNotNull, and, or, not, between, sql } from 'drizzle-orm';

eq(col, value)           // =
ne(col, value)           // <>
gt(col, value)           // >
gte(col, value)          // >=
lt(col, value)           // <
lte(col, value)          // <=
like(col, '%pat%')       // LIKE
ilike(col, '%pat%')      // ILIKE (case-insensitive)
inArray(col, [1,2,3])    // IN
isNull(col)              // IS NULL
isNotNull(col)           // IS NOT NULL
between(col, a, b)       // BETWEEN
and(cond1, cond2)        // AND
or(cond1, cond2)         // OR
not(cond)                // NOT
```

## Select Queries

```typescript
// Basic
await db.select().from(users);
await db.select({ id: users.id }).from(users);

// Where
await db.select().from(users).where(eq(users.id, id));

// Conditional filters (undefined skips condition)
await db.select().from(users).where(and(
  eq(users.active, true),
  term ? ilike(users.name, `%${term}%`) : undefined,
));

// Order, Limit, Offset
await db.select().from(users)
  .orderBy(desc(users.createdAt))
  .limit(20)
  .offset(40);

// Join
await db.select().from(users)
  .leftJoin(posts, eq(posts.authorId, users.id));
```

## Relational Queries

```typescript
// Must pass schema to drizzle()
const db = drizzle(client, { schema });

// Find many
await db.query.users.findMany();
await db.query.users.findMany({
  where: eq(users.active, true),
  orderBy: [desc(users.createdAt)],
  limit: 20,
});

// Find first
await db.query.users.findFirst({
  where: eq(users.id, id),
});

// With relations
await db.query.users.findFirst({
  where: eq(users.id, id),
  with: {
    posts: true,
    profile: true,
  },
});

// Nested relations with filters
await db.query.users.findFirst({
  with: {
    posts: {
      where: eq(posts.published, true),
      orderBy: [desc(posts.createdAt)],
      limit: 10,
      with: { comments: true },
    },
  },
});

// Select specific columns
await db.query.users.findFirst({
  columns: { id: true, email: true },
  with: {
    posts: { columns: { title: true } },
  },
});
```

## Aggregations

```typescript
import { count, sum, avg, min, max } from 'drizzle-orm';

// Count
const [{ total }] = await db.select({ total: count() }).from(users);

// Group by
await db.select({
  authorId: posts.authorId,
  postCount: count(),
}).from(posts).groupBy(posts.authorId);

// Having
.having(gt(count(), 10));
```

## Prepared Statements

```typescript
const getUser = db.select().from(users)
  .where(eq(users.id, sql.placeholder('id')))
  .prepare('get_user');

const user = await getUser.execute({ id });
```
