# KV Gotchas & Troubleshooting

## Eventual Consistency

```typescript
// ❌ Read immediately after write — may see stale value in other regions
await env.MY_KV.put("key", "value");
const value = await env.MY_KV.get("key"); // May be null globally

// ✅ Return confirmation without re-reading
await env.MY_KV.put("key", "value");
return new Response("Updated", { status: 200 });

// ✅ Use the local value directly
const newValue = "updated";
await env.MY_KV.put("key", newValue);
return new Response(newValue);
```

**Propagation:** Writes visible immediately in same location, ≤60s globally.

## Null Handling

```typescript
// ❌ No null check — throws if key missing
const value = await env.MY_KV.get("key");
const result = value.toUpperCase();

// ✅ Explicit null check
const value = await env.MY_KV.get("key");
if (value === null) return new Response("Not found", { status: 404 });
return new Response(value);

// ✅ Nullish coalescing default
const value = (await env.MY_KV.get("config")) ?? "default-config";
```

## Concurrent Writes

```typescript
// ❌ Concurrent writes to same key — 429 rate limit
await Promise.all([
  env.MY_KV.put("counter", "1"),
  env.MY_KV.put("counter", "2")
]);

// ✅ Sequential writes
await env.MY_KV.put("counter", "3");

// ✅ Unique keys for concurrent writes
await Promise.all([
  env.MY_KV.put("counter:1", "1"),
  env.MY_KV.put("counter:2", "2")
]);

// ✅ Retry with exponential backoff
async function putWithRetry(kv: KVNamespace, key: string, value: string) {
  let delay = 1000;
  for (let i = 0; i < 5; i++) {
    try {
      await kv.put(key, value);
      return;
    } catch (err) {
      if (err.message.includes("429") && i < 4) {
        await new Promise(resolve => setTimeout(resolve, delay));
        delay *= 2;
      } else throw err;
    }
  }
}
```

**Limit:** 1 write/second per key (all plans).

## Bulk Operations

```typescript
// ❌ Individual gets — 3 separate operations
const user1 = await env.USERS.get("user:1");
const user2 = await env.USERS.get("user:2");
const user3 = await env.USERS.get("user:3");

// ✅ Bulk get — 1 operation
const users = await env.USERS.get(["user:1", "user:2", "user:3"]);
```

**Note:** Bulk write not available in Workers (CLI/API only).

## Limits & Pricing

| Limit / Pricing | Value |
|-----------------|-------|
| Key size | 512 bytes max |
| Value size | 25 MiB max |
| Metadata | 1024 bytes max |
| cacheTtl | 60s minimum |
| Reads | $0.50 per 10M |
| Writes | $5.00 per 1M |
| Deletes | $5.00 per 1M |
| Storage | $0.50 per GB-month |

## Read Next

- [kv.md](./kv.md) - Core API, when to use KV vs D1/DO/R2
- [kv-patterns.md](./kv-patterns.md) - Caching, sessions, rate limiting, A/B testing
