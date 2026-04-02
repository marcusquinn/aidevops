# Cloudflare Workers KV

Globally distributed, eventually consistent key-value store for read-heavy, low-latency access.

## Best Fit

- Use for config storage, user sessions, feature flags, caching, and A/B testing.
- Choose D1 or Durable Objects when you need strong consistency.

## Core Properties

| Property | Detail |
|----------|--------|
| Consistency | Eventual; writes visible immediately in the same location and within 60s globally |
| Performance | Read optimized with automatic edge replication |
| Limits | 25 MiB value per key, 1024-byte metadata |
| Write rate | 1 write/second per key; exceed it and expect 429s |

## Quick Start

```bash
wrangler kv namespace create MY_NAMESPACE
# Add binding to wrangler.jsonc
```

```typescript
await env.MY_KV.put("key", "value", { expirationTtl: 300 }); // Write
const value = await env.MY_KV.get("key");                     // Read string
const json = await env.MY_KV.get<Config>("config", "json");   // Read typed JSON
```

## Core API

| Method | Purpose | Returns |
|--------|---------|---------|
| `get(key, type?)` | Single read | `string \| null` |
| `get(keys, type?)` | Bulk read (≤100 keys) | `Map<string, T \| null>` |
| `put(key, value, options?)` | Write | `Promise<void>` |
| `delete(key)` | Delete | `Promise<void>` |
| `list(options?)` | List keys | `{ keys, list_complete, cursor? }` |
| `getWithMetadata(key)` | Read with metadata | `{ value, metadata }` |

## Read Next

- [kv-patterns.md](./kv-patterns.md) - Caching, sessions, rate limiting, A/B testing
- [kv-gotchas.md](./kv-gotchas.md) - Eventual consistency, concurrent writes, value limits
- [workers.md](./workers.md) - Worker runtime for KV access
- [d1.md](./d1.md) - Better fit for relational or strongly consistent data
- [durable-objects.md](./durable-objects.md) - Strong consistency and coordination
