# Drizzle Relations & Relational Queries

Relations are **application-level** (not database constraints). Pass `schema` to `drizzle()` to enable the relational queries API.

| API | Use Case | N+1 Safe |
|-----|----------|----------|
| **Relational** (`db.query...`) | Nested data, simple CRUD | Yes |
| **SQL-like** (`db.select()...`) | Complex queries, joins, aggregations | Manual |

```typescript
import { relations } from 'drizzle-orm';
import { pgTable, uuid, text, timestamp, AnyPgColumn } from 'drizzle-orm/pg-core';
```

## Relation Types

### One-to-Many

```typescript
export const usersRelations = relations(users, ({ many }) => ({
  posts: many(posts),
}));

export const postsRelations = relations(posts, ({ one }) => ({
  author: one(users, { fields: [posts.authorId], references: [users.id] }),
}));
```

### One-to-One

```typescript
export const usersRelations = relations(users, ({ one }) => ({
  profile: one(profiles),
}));

export const profilesRelations = relations(profiles, ({ one }) => ({
  user: one(users, { fields: [profiles.userId], references: [users.id] }),
}));
```

### Many-to-Many (junction table)

```typescript
export const usersToGroups = pgTable('users_to_groups', {
  userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  groupId: uuid('group_id').notNull().references(() => groups.id, { onDelete: 'cascade' }),
  joinedAt: timestamp('joined_at').notNull().defaultNow(),
  role: text('role').notNull().default('member'),
}, (t) => [primaryKey({ columns: [t.userId, t.groupId] })]);

export const usersRelations = relations(users, ({ many }) => ({
  usersToGroups: many(usersToGroups),
}));
export const groupsRelations = relations(groups, ({ many }) => ({
  usersToGroups: many(usersToGroups),
}));
export const usersToGroupsRelations = relations(usersToGroups, ({ one }) => ({
  user: one(users, { fields: [usersToGroups.userId], references: [users.id] }),
  group: one(groups, { fields: [usersToGroups.groupId], references: [groups.id] }),
}));

// Flatten junction in query result
const userWithGroups = await db.query.users.findFirst({
  where: eq(users.id, userId),
  with: { usersToGroups: { with: { group: true } } },
});
const groups = userWithGroups?.usersToGroups.map(utg => ({
  ...utg.group, joinedAt: utg.joinedAt, role: utg.role,
}));
```

### Self-Referential

```typescript
export const categoriesRelations = relations(categories, ({ one, many }) => ({
  parent: one(categories, {
    fields: [categories.parentId],
    references: [categories.id],
    relationName: 'parent',
  }),
  children: many(categories, { relationName: 'parent' }),
}));

// parentId column must use AnyPgColumn to avoid circular reference
parentId: uuid('parent_id').references((): AnyPgColumn => categories.id),

// Query 2 levels deep
const category = await db.query.categories.findFirst({
  where: eq(categories.id, categoryId),
  with: { parent: true, children: { with: { children: true } } },
});
```

## Relational Queries API

### Setup

```typescript
import { drizzle } from 'drizzle-orm/postgres-js';
import * as schema from './schema';

export const db = drizzle(postgres(process.env.DATABASE_URL!), { schema }); // schema required
```

### findMany / findFirst

```typescript
const activeUsers = await db.query.users.findMany({
  where: eq(users.status, 'active'),
  orderBy: [desc(users.createdAt)],
  limit: 20,
  offset: 40,
});

const user = await db.query.users.findFirst({ where: eq(users.email, email) });
if (!user) throw new NotFoundError();
```

### with (relations), columns, extras

```typescript
// Load multiple relations; filter nested
const userWithAll = await db.query.users.findFirst({
  where: eq(users.id, userId),
  with: {
    posts: {
      where: gt(posts.createdAt, oneWeekAgo),
      orderBy: [desc(posts.createdAt)],
      limit: 10,
    },
    profile: true,
    usersToGroups: { with: { group: true } },
  },
});

// Column selection (include or exclude)
const userBasic = await db.query.users.findFirst({
  columns: { id: true, email: true },                    // include
  // columns: { password: false },                       // exclude
  with: { posts: { columns: { id: true, title: true } } },
});

// Computed fields
const usersWithPostCount = await db.query.users.findMany({
  extras: {
    postCount: sql<number>`(SELECT count(*) FROM posts WHERE posts.author_id = users.id)`.as('post_count'),
  },
});
```

## Complex Example: Feed Query

```typescript
const feed = await db.query.posts.findMany({
  where: eq(posts.published, true),
  orderBy: [desc(posts.createdAt)],
  limit: 20,
  columns: { id: true, title: true, createdAt: true },
  with: { author: { columns: { id: true, name: true } } },
  extras: {
    commentCount: sql<number>`(SELECT count(*) FROM comments WHERE comments.post_id = posts.id)`.as('comment_count'),
    likeCount: sql<number>`(SELECT count(*) FROM likes WHERE likes.post_id = posts.id)`.as('like_count'),
  },
});
```

## Type Inference

```typescript
import type { InferSelectModel, InferInsertModel } from 'drizzle-orm';

type User = InferSelectModel<typeof users>;
type NewUser = InferInsertModel<typeof users>;

// Infer from query result (with relations)
const getUser = (id: string) => db.query.users.findFirst({ where: eq(users.id, id), with: { posts: true } });
type UserWithPosts = NonNullable<Awaited<ReturnType<typeof getUser>>>;

// Partial select
const result = await db.select({ id: users.id, email: users.email }).from(users);
type UserBasic = typeof result[number];
```

## Relations vs Joins

| Use | When |
|-----|------|
| **Relational queries** | Simple CRUD, nested/hierarchical data, automatic N+1 prevention |
| **SQL-like joins** | Complex aggregations, filtering on related data, performance-critical queries |

```typescript
// Relational — nested result: { id, name, posts: [{ id, title }, ...] }
const userWithPosts = await db.query.users.findFirst({ where: eq(users.id, userId), with: { posts: true } });

// Join — flat result: [{ users: { id, name }, posts: { id, title } | null }, ...]
const userWithPosts = await db.select().from(users)
  .leftJoin(posts, eq(posts.authorId, users.id))
  .where(eq(users.id, userId));
```
