# R2 Pattern: Batch Delete by Prefix

```typescript
async function deletePrefix(prefix: string, env: Env) {
  let cursor: string | undefined;
  let truncated = true;

  while (truncated) {
    const listed = await env.MY_BUCKET.list({ prefix, limit: 1000, cursor });
    if (listed.objects.length > 0) {
      await env.MY_BUCKET.delete(listed.objects.map(o => o.key));
    }
    truncated = listed.truncated;
    cursor = listed.cursor;
  }
}
```
