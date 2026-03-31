# In-Memory Caching

```typescript
export class UserCache extends DurableObject {
  cache = new Map<string, User>();
  async getUser(id: string): Promise<User> {
    if (this.cache.has(id)) return this.cache.get(id)!;
    const user = await this.ctx.storage.get<User>(`user:${id}`);
    if (user) this.cache.set(id, user);
    return user;
  }
  async updateUser(id: string, data: Partial<User>) {
    const updated = { ...await this.getUser(id), ...data };
    this.cache.set(id, updated);
    await this.ctx.storage.put(`user:${id}`, updated);
    return updated;
  }
}
```
