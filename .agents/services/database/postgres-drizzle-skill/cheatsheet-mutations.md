<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Mutations

All mutation methods support `.returning()` to get affected rows back.

## Insert

```typescript
const [user] = await db.insert(users).values({ email, name }).returning();

// Batch
await db.insert(users).values([
  { email: 'a@b.com', name: 'A' },
  { email: 'b@b.com', name: 'B' },
]);

// Upsert (on conflict)
await db.insert(users).values({ email, name }).onConflictDoUpdate({
  target: users.email,
  set: { name },
});
await db.insert(users).values({ email, name }).onConflictDoNothing();
```

## Update

```typescript
await db.update(users).set({ status: 'active' }).where(eq(users.id, id));

// Increment
await db.update(posts)
  .set({ views: sql`${posts.views} + 1` })
  .where(eq(posts.id, id));
```

## Delete

```typescript
await db.delete(users).where(eq(users.id, id));
const [deleted] = await db.delete(users).where(eq(users.id, id)).returning();
```

## Transactions

```typescript
await db.transaction(async (tx) => {
  const [user] = await tx.insert(users).values({ ... }).returning();
  await tx.insert(profiles).values({ userId: user.id });
  return user;
});

// Rollback
await db.transaction(async (tx) => {
  await tx.insert(users).values({ ... });
  if (condition) tx.rollback(); // Throws
});
```
