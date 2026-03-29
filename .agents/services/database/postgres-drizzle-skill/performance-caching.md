# Performance: Caching

```typescript
async function getCachedUser(userId: string) {
  const cacheKey = `user:${userId}`;
  const cached = await redis.get(cacheKey);
  if (cached) return JSON.parse(cached);
  const user = await db.query.users.findFirst({ where: eq(users.id, userId) });
  if (user) await redis.setex(cacheKey, 3600, JSON.stringify(user));
  return user;
}
// On write: await db.update(users).set(data).where(eq(users.id, userId)); await redis.del(`user:${userId}`);
```
