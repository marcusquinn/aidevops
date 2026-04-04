---
description: Drizzle ORM - type-safe database queries, migrations, schema
mode: subagent
tools:
  read: true
  edit: true
  glob: true
  grep: true
  webfetch: true
  context7_*: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

## Quick Reference

- **Packages**: `drizzle-orm`, `drizzle-kit`, `drizzle-zod`
- **Docs**: Context7 MCP for current documentation
- **Key traits**: Full TS inference, SQL-like builder, zero runtime deps, auto-migrations

```tsx
// Schema (packages/db/src/schema/users.ts)
import { pgTable, text, timestamp, uuid } from "drizzle-orm/pg-core";
export const users = pgTable("users", {
  id: uuid("id").primaryKey().defaultRandom(),
  email: text("email").notNull().unique(),
  name: text("name"),
  createdAt: timestamp("created_at").defaultNow().notNull(),
  updatedAt: timestamp("updated_at").defaultNow().notNull(), // INSERT only; use .$onUpdate() or DB trigger for UPDATE
});

// CRUD
import { db } from "@workspace/db";
import { users } from "@workspace/db/schema";
import { eq } from "drizzle-orm";
const allUsers = await db.select().from(users);
const user = await db.select().from(users).where(eq(users.email, "test@example.com")).limit(1);
const newUser = await db.insert(users).values({ email: "new@example.com", name: "New User" }).returning();
await db.update(users).set({ name: "Updated Name" }).where(eq(users.id, userId));
await db.delete(users).where(eq(users.id, userId));

// Zod integration
import { createInsertSchema, createSelectSchema } from "drizzle-zod";
export const insertUserSchema = createInsertSchema(users);
export const selectUserSchema = createSelectSchema(users);
app.post("/users", zValidator("json", insertUserSchema), async (c) =>
  c.json((await db.insert(users).values(c.req.valid("json")).returning())[0])
);
```

```bash
# Migrations
pnpm db:generate   # generate migration from schema changes
pnpm db:migrate    # apply migrations
pnpm db:push       # push schema directly (dev only)
pnpm db:studio     # open Drizzle Studio
```

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Missing `.returning()` | Insert/update don't return data by default — add `.returning()` |
| Skipping transactions | Related inserts must be in a transaction to prevent partial failures |
| Schema drift | Always run `db:generate` after schema changes; review SQL before applying |
| Missing indexes | Add `.index()` in schema for frequently queried columns |

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
await db.transaction(async (tx) => {
  const [user] = await tx.insert(users).values({ email: "test@example.com" }).returning();
  await tx.insert(posts).values({ title: "First Post", authorId: user.id });
});

// Connection — packages/db/src/server.ts
import { drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";
import * as schema from "./schema";
export const db = drizzle(postgres(process.env.DATABASE_URL!), { schema });
```

## Seeding

```tsx
// packages/db/src/scripts/seed.ts — key patterns:
// 1. Guard production: throw if NODE_ENV=production && !ALLOW_DB_WIPE
// 2. Transaction: delete children before parents, then insert
// 3. Use .returning() to chain parent→child inserts
seed().catch((err) => { console.error(err); process.exit(1); });
```

## Related

- `tools/api/hono.md` — API routes using Drizzle
- `workflows/sql-migrations.md` — migration best practices
- Context7 MCP for Drizzle documentation
