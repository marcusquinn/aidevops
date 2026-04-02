# KV Gotchas & Troubleshooting

## Eventual Consistency

```typescript
// ❌ Read immediately after write (may see stale globally)
await env.MY_KV.put("key", "value");
const value = await env.MY_KV.get("key"); // May be null in other regions

// ✅ Return confirmation without reading
await env.MY_KV.put("key", "value");
return new Response("Updated", { status: 200 });

// ✅ Use local value
const newValue = "updated";
await env.MY_KV.put("key", newValue);
return new Response(newValue);
```

**Propagation:** Writes visible immediately in same location, ≤60s globally.

## Concurrent Writes

```typescript
// ❌ Concurrent writes to same key (429 rate limit)
await Promise.all([
  env.MY_KV.put("counter", "1"),
  env.MY_KV.put("counter", "2")
]); // 429 error

// ✅ Sequential writes
await env.MY_KV.put("counter", "3");

// ✅ Unique keys for concurrent writes
await Promise.all([
  env.MY_KV.put("counter:1", "1"),
  env.MY_KV.put("counter:2", "2")
]);

// ✅ Retry with backoff
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
// ❌ Multiple individual gets (uses 3 operations)
const user1 = await env.USERS.get("user:1");
const user2 = await env.USERS.get("user:2");
const user3 = await env.USERS.get("user:3");

// ✅ Single bulk get (uses 1 operation)
const users = await env.USERS.get(["user:1", "user:2", "user:3"]);
```

**Note:** Bulk write NOT available in Workers (only via CLI/API).

## Null Handling

```typescript
// ❌ No null check
const value = await env.MY_KV.get("key");
const result = value.toUpperCase(); // Error if null

// ✅ Check for null
const value = await env.MY_KV.get("key");
if (value === null) return new Response("Not found", { status: 404 });
return new Response(value);

// ✅ Provide default
const value = (await env.MY_KV.get("config")) ?? "default-config";
```

## Limits & Pricing

| | |
|---|---|
| Key size | 512 bytes max |
| Value size | 25 MiB max |
| Metadata | 1024 bytes max |
| cacheTtl | 60s minimum |
| Reads | $0.50 per 10M |
| Writes | $5.00 per 1M |
| Deletes | $5.00 per 1M |
| Storage | $0.50 per GB-month |

## When to Use

| Use KV | Use Instead |
|--------|-------------|
| Read-heavy, globally distributed, eventually consistent | Strong consistency → Durable Objects |
| Low-latency reads, key-value access | Write-heavy → D1 or Durable Objects |
| | Relational queries → D1 |
| | Large files (>25 MiB) → R2 |
| | Atomic operations → Durable Objects |
