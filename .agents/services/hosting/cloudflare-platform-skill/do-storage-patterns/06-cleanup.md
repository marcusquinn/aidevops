# Cleanup

```typescript
async cleanup() {
  await this.ctx.storage.deleteAlarm(); // Separate from deleteAll
  await this.ctx.storage.deleteAll();
}
```
