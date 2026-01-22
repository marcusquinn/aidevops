---
description: Drizzle ORM - type-safe database queries, migrations, schema
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
  context7_*: true
---

# Drizzle ORM - Type-Safe Database

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Type-safe ORM for SQL databases
- **Packages**: `drizzle-orm`, `drizzle-kit`, `drizzle-zod`
- **Docs**: Use Context7 MCP for current documentation

**Key Features**:
- Full TypeScript inference from schema
- SQL-like query builder
- Zero dependencies at runtime
- Automatic migrations

**Schema Definition**:

```tsx
// packages/db/src/schema/users.ts
import { pgTable, text, timestamp, uuid } from "drizzle-orm/pg-core";

export const users = pgTable("users", {
  id: uuid("id").primaryKey().defaultRandom(),
  email: text("email").notNull().unique(),
  name: text("name"),
  createdAt: timestamp("created_at").defaultNow().notNull(),
  updatedAt: timestamp("updated_at").defaultNow().notNull(),
});
```

**Basic Queries**:

```tsx
import { db } from "@workspace/db";
import { users } from "@workspace/db/schema";
import { eq } from "drizzle-orm";

// Select all
const allUsers = await db.select().from(users);

// Select with filter
const user = await db
  .select()
  .from(users)
  .where(eq(users.email, "test@example.com"))
  .limit(1);

// Insert
const newUser = await db
  .insert(users)
  .values({ email: "new@example.com", name: "New User" })
  .returning();

// Update
await db
  .update(users)
  .set({ name: "Updated Name" })
  .where(eq(users.id, userId));

// Delete
await db.delete(users).where(eq(users.id, userId));
```

**Migration Commands**:

```bash
# Generate migration from schema changes
pnpm db:generate

# Apply migrations
pnpm db:migrate

# Push schema directly (dev only)
pnpm db:push

# Open Drizzle Studio
pnpm db:studio
```

**Zod Integration**:

```tsx
import { createInsertSchema, createSelectSchema } from "drizzle-zod";
import { users } from "./schema";

export const insertUserSchema = createInsertSchema(users);
export const selectUserSchema = createSelectSchema(users);

// Use in API validation
app.post("/users", zValidator("json", insertUserSchema), async (c) => {
  const data = c.req.valid("json");
  const user = await db.insert(users).values(data).returning();
  return c.json(user[0]);
});
```

<!-- AI-CONTEXT-END -->

## Detailed Patterns

### Relations

```tsx
import { relations } from "drizzle-orm";
import { pgTable, text, uuid } from "drizzle-orm/pg-core";

export const users = pgTable("users", {
  id: uuid("id").primaryKey().defaultRandom(),
  name: text("name"),
});

export const posts = pgTable("posts", {
  id: uuid("id").primaryKey().defaultRandom(),
  title: text("title").notNull(),
  authorId: uuid("author_id").references(() => users.id),
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
```

### Query with Relations

```tsx
// Using query API (recommended for relations)
const usersWithPosts = await db.query.users.findMany({
  with: {
    posts: true,
  },
});

// Nested relations
const usersWithPostsAndComments = await db.query.users.findMany({
  with: {
    posts: {
      with: {
        comments: true,
      },
    },
  },
});
```

### Complex Queries

```tsx
import { and, or, like, gt, desc, sql } from "drizzle-orm";

// Multiple conditions
const results = await db
  .select()
  .from(users)
  .where(
    and(
      like(users.email, "%@example.com"),
      gt(users.createdAt, new Date("2024-01-01"))
    )
  )
  .orderBy(desc(users.createdAt))
  .limit(10);

// Raw SQL when needed
const count = await db
  .select({ count: sql<number>`count(*)` })
  .from(users);
```

### Transactions

```tsx
await db.transaction(async (tx) => {
  const user = await tx
    .insert(users)
    .values({ email: "test@example.com" })
    .returning();

  await tx.insert(posts).values({
    title: "First Post",
    authorId: user[0].id,
  });
});
```

### Database Connection

```tsx
// packages/db/src/server.ts
import { drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";
import * as schema from "./schema";

const client = postgres(process.env.DATABASE_URL!);
export const db = drizzle(client, { schema });
```

### Seeding

```tsx
// packages/db/src/scripts/seed.ts
import { db } from "../server";
import { users, posts } from "../schema";

async function seed() {
  console.log("Seeding database...");

  // Clear existing data
  await db.delete(posts);
  await db.delete(users);

  // Insert seed data
  const [user] = await db
    .insert(users)
    .values({ email: "admin@example.com", name: "Admin" })
    .returning();

  await db.insert(posts).values([
    { title: "First Post", authorId: user.id },
    { title: "Second Post", authorId: user.id },
  ]);

  console.log("Seeding complete!");
}

seed().catch(console.error);
```

## Common Mistakes

1. **Forgetting `.returning()`**
   - Insert/update don't return data by default
   - Add `.returning()` to get inserted/updated rows

2. **Not using transactions**
   - Related inserts should be in transaction
   - Prevents partial data on failure

3. **Schema drift**
   - Always run `db:generate` after schema changes
   - Review generated SQL before applying

4. **Missing indexes**
   - Add indexes for frequently queried columns
   - Use `.index()` in schema definition

## Related

- `tools/api/hono.md` - API routes using Drizzle
- `workflows/sql-migrations.md` - Migration best practices
- Context7 MCP for Drizzle documentation
