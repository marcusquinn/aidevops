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

- **Packages**: `drizzle-orm`, `drizzle-kit`, `drizzle-zod`
- **Docs**: Context7 MCP for current documentation
- **Key traits**: Full TS inference, SQL-like builder, zero runtime deps, auto-migrations

**Schema** (`packages/db/src/schema/users.ts`):

```tsx
import { pgTable, text, timestamp, uuid } from "drizzle-orm/pg-core";
export const users = pgTable("users", {
  id: uuid("id").primaryKey().defaultRandom(),
  email: text("email").notNull().unique(),
  name: text("name"),
  createdAt: timestamp("created_at").defaultNow().notNull(),
  updatedAt: timestamp("updated_at").defaultNow().notNull(), // only sets on INSERT; use .$onUpdate() or DB trigger for UPDATE
});
```

**CRUD**:

```tsx
import { db } from "@workspace/db";
import { users } from "@workspace/db/schema";
import { eq } from "drizzle-orm";
const allUsers = await db.select().from(users);
const user = await db.select().from(users).where(eq(users.email, "test@example.com")).limit(1);
const newUser = await db.insert(users).values({ email: "new@example.com", name: "New User" }).returning();
await db.update(users).set({ name: "Updated Name" }).where(eq(users.id, userId));
await db.delete(users).where(eq(users.id, userId));
```

**Migrations**:

```bash
pnpm db:generate   # generate migration from schema changes
pnpm db:migrate    # apply migrations
pnpm db:push       # push schema directly (dev only)
pnpm db:studio     # open Drizzle Studio
```

**Zod integration**:

```tsx
import { createInsertSchema, createSelectSchema } from "drizzle-zod";
export const insertUserSchema = createInsertSchema(users);
export const selectUserSchema = createSelectSchema(users);
// Use in API validation (e.g. Hono + zValidator)
app.post("/users", zValidator("json", insertUserSchema), async (c) =>
  c.json((await db.insert(users).values(c.req.valid("json")).returning())[0])
);
```

<!-- AI-CONTEXT-END -->

## Relations

```tsx
import { relations } from "drizzle-orm";
export const posts = pgTable("posts", {
  id: uuid("id").primaryKey().defaultRandom(),
  title: text("title").notNull(),
  authorId: uuid("author_id").references(() => users.id),
});
export const usersRelations = relations(users, ({ many }) => ({ posts: many(posts) }));
export const postsRelations = relations(posts, ({ one }) => ({
  author: one(users, { fields: [posts.authorId], references: [users.id] }),
}));

// Query with relations — use query API (not .select())
const usersWithPosts = await db.query.users.findMany({ with: { posts: true } });
const deep = await db.query.users.findMany({ with: { posts: { with: { comments: true } } } });
```

## Complex Queries

```tsx
import { and, like, gt, desc, sql } from "drizzle-orm";
const results = await db.select().from(users)
  .where(and(like(users.email, "%@example.com"), gt(users.createdAt, new Date("2024-01-01"))))
  .orderBy(desc(users.createdAt)).limit(10);
const count = await db.select({ count: sql<number>`count(*)` }).from(users);
```

## Transactions & Connection

```tsx
// Transaction
await db.transaction(async (tx) => {
  const [user] = await tx.insert(users).values({ email: "test@example.com" }).returning();
  await tx.insert(posts).values({ title: "First Post", authorId: user.id });
});

// Connection (packages/db/src/server.ts)
import { drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";
import * as schema from "./schema";
export const db = drizzle(postgres(process.env.DATABASE_URL!), { schema });
```

## Seeding (`packages/db/src/scripts/seed.ts`)

```tsx
async function seed() {
  if (process.env.NODE_ENV === "production" && process.env.ALLOW_DB_WIPE !== "true")
    throw new Error("Seeding disabled in production. Set ALLOW_DB_WIPE=true to override.");
  await db.transaction(async (tx) => {
    await tx.delete(posts); // children before parents
    await tx.delete(users);
    const [user] = await tx.insert(users).values({ email: "admin@example.com", name: "Admin" }).returning();
    await tx.insert(posts).values([{ title: "First Post", authorId: user.id }, { title: "Second Post", authorId: user.id }]);
  });
}
seed().catch((err) => { console.error(err); process.exit(1); });
```

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Missing `.returning()` | Insert/update don't return data by default — add `.returning()` |
| Skipping transactions | Related inserts must be in a transaction to prevent partial failures |
| Schema drift | Always run `db:generate` after schema changes; review SQL before applying |
| Missing indexes | Add `.index()` in schema for frequently queried columns |

## Related

- `tools/api/hono.md` — API routes using Drizzle
- `workflows/sql-migrations.md` — migration best practices
- Context7 MCP for Drizzle documentation
