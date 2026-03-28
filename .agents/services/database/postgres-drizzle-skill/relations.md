# Drizzle Relations & Relational Queries

| API | Use Case | N+1 Safe |
|-----|----------|----------|
| **SQL-like** (`db.select()...`) | Complex queries, joins, aggregations | Manual |
| **Relational** (`db.query...`) | Nested data, simple CRUD | Yes |

Relations are **application-level** (not database constraints). They enable the relational queries API.

```typescript
import { relations } from 'drizzle-orm';
import { pgTable, uuid, text, timestamp, integer } from 'drizzle-orm/pg-core';
```

## One-to-Many

```typescript
export const users = pgTable('users', {
  id: uuid('id').primaryKey().defaultRandom(),
  name: text('name').notNull(),
});

export const posts = pgTable('posts', {
  id: uuid('id').primaryKey().defaultRandom(),
  title: text('title').notNull(),
  authorId: uuid('author_id').notNull().references(() => users.id),
});

export const usersRelations = relations(users, ({ many }) => ({
  posts: many(posts),
}));

export const postsRelations = relations(posts, ({ one }) => ({
  author: one(users, {
    fields: [posts.authorId],
    references: [users.id],
  }),
}));

// Query
const userWithPosts = await db.query.users.findFirst({
  where: eq(users.id, userId),
  with: { posts: true },
});
```

## One-to-One

```typescript
export const profiles = pgTable('profiles', {
  id: uuid('id').primaryKey().defaultRandom(),
  userId: uuid('user_id').notNull().unique().references(() => users.id),
  bio: text('bio'),
  avatarUrl: text('avatar_url'),
});

export const usersRelations = relations(users, ({ one }) => ({
  profile: one(profiles),
}));

export const profilesRelations = relations(profiles, ({ one }) => ({
  user: one(users, {
    fields: [profiles.userId],
    references: [users.id],
  }),
}));

// Query
const userWithProfile = await db.query.users.findFirst({
  where: eq(users.id, userId),
  with: { profile: true },
});
```

## Many-to-Many

```typescript
export const groups = pgTable('groups', {
  id: uuid('id').primaryKey().defaultRandom(),
  name: text('name').notNull(),
});

export const usersToGroups = pgTable('users_to_groups', {
  userId: uuid('user_id').notNull().references(() => users.id, { onDelete: 'cascade' }),
  groupId: uuid('group_id').notNull().references(() => groups.id, { onDelete: 'cascade' }),
  joinedAt: timestamp('joined_at').notNull().defaultNow(),
  role: text('role').notNull().default('member'),
}, (table) => [
  primaryKey({ columns: [table.userId, table.groupId] }),
]);

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

// Query + flatten junction
const userWithGroups = await db.query.users.findFirst({
  where: eq(users.id, userId),
  with: { usersToGroups: { with: { group: true } } },
});
const groups = userWithGroups?.usersToGroups.map(utg => ({
  ...utg.group,
  joinedAt: utg.joinedAt,
  role: utg.role,
}));
```

## Self-Referential

```typescript
import { AnyPgColumn } from 'drizzle-orm/pg-core';

export const categories = pgTable('categories', {
  id: uuid('id').primaryKey().defaultRandom(),
  name: text('name').notNull(),
  parentId: uuid('parent_id').references((): AnyPgColumn => categories.id),
});

export const categoriesRelations = relations(categories, ({ one, many }) => ({
  parent: one(categories, {
    fields: [categories.parentId],
    references: [categories.id],
    relationName: 'parent',
  }),
  children: many(categories, { relationName: 'parent' }),
}));

// Query (2 levels deep)
const category = await db.query.categories.findFirst({
  where: eq(categories.id, categoryId),
  with: {
    parent: true,
    children: { with: { children: true } },
  },
});
```

## Relational Queries API

### Setup

```typescript
import { drizzle } from 'drizzle-orm/postgres-js';
import postgres from 'postgres';
import * as schema from './schema';

const client = postgres(process.env.DATABASE_URL!);
export const db = drizzle(client, { schema });  // Pass schema!
```

### findMany / findFirst

```typescript
const allUsers = await db.query.users.findMany();
const activeUsers = await db.query.users.findMany({
  where: eq(users.status, 'active'),
  orderBy: [desc(users.createdAt)],
  limit: 20,
  offset: 40,
});

const user = await db.query.users.findFirst({
  where: eq(users.email, email),
});
if (!user) throw new NotFoundError();
```

### With Relations

```typescript
// Multiple + nested
const userWithAll = await db.query.users.findFirst({
  where: eq(users.id, userId),
  with: {
    posts: true,
    profile: true,
    usersToGroups: { with: { group: true } },
  },
});

// Nested with filtering
const userWithRecentPosts = await db.query.users.findFirst({
  where: eq(users.id, userId),
  with: {
    posts: {
      where: gt(posts.createdAt, oneWeekAgo),
      orderBy: [desc(posts.createdAt)],
      limit: 10,
    },
  },
});
```

### Selecting Columns

```typescript
// Include specific columns
const userBasic = await db.query.users.findFirst({
  columns: { id: true, email: true },
});

// Exclude columns
const userWithoutPassword = await db.query.users.findFirst({
  columns: { password: false },
});

// Columns on relations
const userWithPostTitles = await db.query.users.findFirst({
  columns: { id: true, name: true },
  with: {
    posts: { columns: { id: true, title: true } },
  },
});
```

### Custom Extras (Computed Fields)

```typescript
const usersWithPostCount = await db.query.users.findMany({
  extras: {
    postCount: sql<number>`(
      SELECT count(*) FROM posts WHERE posts.author_id = users.id
    )`.as('post_count'),
  },
});
```

## Type Inference

```typescript
import type { InferSelectModel, InferInsertModel } from 'drizzle-orm';

type User = InferSelectModel<typeof users>;
type NewUser = InferInsertModel<typeof users>;

// Infer from query result (includes relations)
const getUser = async (id: string) => db.query.users.findFirst({
  where: eq(users.id, id),
  with: { posts: true },
});
type UserWithPosts = NonNullable<Awaited<ReturnType<typeof getUser>>>;
```

## Relations vs Joins

| Use | When |
|-----|------|
| **Relational queries** | Simple CRUD, nested/hierarchical data, automatic N+1 prevention, nested object results |
| **SQL-like joins** | Complex aggregations, filtering on related data, custom cross-table column selection, performance-critical queries |

```typescript
// Relational — nested result: { id, name, posts: [{ id, title }, ...] }
const nested = await db.query.users.findFirst({
  where: eq(users.id, userId),
  with: { posts: true },
});

// Join — flat result: [{ users: { id, name }, posts: { id, title } | null }, ...]
const flat = await db
  .select()
  .from(users)
  .leftJoin(posts, eq(posts.authorId, users.id))
  .where(eq(users.id, userId));
```
