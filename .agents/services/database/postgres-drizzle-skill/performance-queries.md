<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Performance: Drizzle Queries

## Prepared Statements

```typescript
const getUserById = db.select().from(users)
  .where(eq(users.id, sql.placeholder('id')))
  .prepare('get_user_by_id');
const user = await getUserById.execute({ id: 'uuid-1' });
```

## N+1 Prevention

```typescript
// BAD: N+1
for (const post of posts) {
  const author = await db.select().from(users).where(eq(users.id, post.authorId));
}
// GOOD: relational query (single JOIN)
const posts = await db.query.posts.findMany({ with: { author: true } });
// GOOD: manual join
const posts = await db.select().from(posts).leftJoin(users, eq(posts.authorId, users.id));
```

## Select Only Needed Columns

```typescript
const users = await db.select({ id: users.id, email: users.email }).from(users);
const users = await db.query.users.findMany({ columns: { id: true, email: true } });
```

## Batch Operations

```typescript
await db.insert(usersTable).values(users);  // batch insert
for (let i = 0; i < users.length; i += 1000) {  // chunk large batches
  await db.insert(usersTable).values(users.slice(i, i + 1000));
}
// Bulk CASE update
await db.execute(sql`
  UPDATE products SET price = CASE id
    ${sql.join(updates.map(u => sql`WHEN ${u.id} THEN ${u.price}`), sql` `)}
  END WHERE id IN ${sql`(${sql.join(updates.map(u => u.id), sql`, `)})`}
`);
// Upsert
await db.insert(products).values(products).onConflictDoUpdate({
  target: products.sku,
  set: { price: sql`excluded.price`, updatedAt: new Date() },
});
```

## Transactions

```typescript
await db.transaction(async (tx) => {
  const [user] = await tx.insert(users).values({ ... }).returning();
  await tx.insert(profiles).values({ userId: user.id });
});
```
