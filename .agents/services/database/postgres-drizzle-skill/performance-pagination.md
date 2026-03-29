# Performance: Pagination

```typescript
// Offset-based (simple, slow for large offsets)
db.select().from(posts).orderBy(desc(posts.createdAt)).limit(pageSize).offset((page - 1) * pageSize)
// Cursor-based (better performance)
db.select().from(posts)
  .where(cursor ? lt(posts.id, cursor) : undefined)
  .orderBy(desc(posts.id)).limit(limit)
// Keyset (most efficient — composite cursor)
db.select().from(posts)
  .where(cursor ? or(
    lt(posts.createdAt, cursor.createdAt),
    and(eq(posts.createdAt, cursor.createdAt), lt(posts.id, cursor.id))
  ) : undefined)
  .orderBy(desc(posts.createdAt), desc(posts.id)).limit(limit)
```
