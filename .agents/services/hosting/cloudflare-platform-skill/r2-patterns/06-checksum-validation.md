# R2 Pattern: Checksum Validation

```typescript
const hash = await crypto.subtle.digest('SHA-256', data);
await env.MY_BUCKET.put(key, data, { sha256: hash });

// Verify on retrieval
const object = await env.MY_BUCKET.get(key);
const retrievedHash = await crypto.subtle.digest('SHA-256', await object.arrayBuffer());
const valid = object.checksums.sha256 && arrayBuffersEqual(retrievedHash, object.checksums.sha256);
```
