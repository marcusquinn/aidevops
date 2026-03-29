# KV Patterns & Best Practices

## API Response Caching

```typescript
async function getCachedData(env: Env, key: string, fetcher: () => Promise<any>) {
  const cached = await env.MY_KV.get(key, "json");
  if (cached) return cached;
  const data = await fetcher();
  await env.MY_KV.put(key, JSON.stringify(data), { expirationTtl: 300 });
  return data;
}
```

## Session Management

```typescript
interface Session { userId: string; expiresAt: number; }

async function createSession(env: Env, userId: string): Promise<string> {
  const sessionId = crypto.randomUUID();
  await env.SESSIONS.put(
    `session:${sessionId}`,
    JSON.stringify({ userId, expiresAt: Date.now() + 86_400_000 }),
    { expirationTtl: 86400, metadata: { createdAt: Date.now() } }
  );
  return sessionId;
}

async function getSession(env: Env, sessionId: string): Promise<Session | null> {
  const data = await env.SESSIONS.get<Session>(`session:${sessionId}`, "json");
  return data && data.expiresAt >= Date.now() ? data : null;
}
```

## Feature Flags

```typescript
async function getFeatureFlags(env: Env): Promise<Record<string, boolean>> {
  return await env.CONFIG.get<Record<string, boolean>>(
    "features:flags", { type: "json", cacheTtl: 600 }
  ) || {};
}

export default {
  async fetch(request, env): Promise<Response> {
    const flags = await getFeatureFlags(env);
    if (flags.beta_feature) return handleBetaFeature(request);
    return handleStandardFlow(request);
  }
};
```

## Rate Limiting

```typescript
async function rateLimit(env: Env, id: string, limit: number, windowSec: number): Promise<boolean> {
  const key = `ratelimit:${id}`;
  const now = Date.now();
  const data = await env.MY_KV.get<{ count: number; resetAt: number }>(key, "json");

  if (!data || data.resetAt < now) {
    await env.MY_KV.put(key, JSON.stringify({ count: 1, resetAt: now + windowSec * 1000 }),
      { expirationTtl: windowSec });
    return true;
  }
  if (data.count >= limit) return false;

  await env.MY_KV.put(key, JSON.stringify({ count: data.count + 1, resetAt: data.resetAt }),
    { expirationTtl: Math.ceil((data.resetAt - now) / 1000) });
  return true;
}
```

## A/B Testing

```typescript
async function getVariant(env: Env, userId: string, testName: string): Promise<string> {
  const assigned = await env.AB_TESTS.get(`test:${testName}:user:${userId}`);
  if (assigned) return assigned;

  const test = await env.AB_TESTS.get<{ variants: string[]; weights: number[] }>(
    `test:${testName}:config`, { type: "json", cacheTtl: 3600 });
  if (!test) return "control";

  // Deterministic assignment via hash
  const random = ((await hashString(userId)) % 100) / 100;
  let cumulative = 0;
  const variant = test.variants.find((_, i) => (cumulative += test.weights[i]) > random)
    ?? test.variants[0];

  await env.AB_TESTS.put(`test:${testName}:user:${userId}`, variant, { expirationTtl: 2592000 });
  return variant;
}
```

## Coalesce Cold Keys

```typescript
// BAD: Many individual keys
await env.KV.put("user:123:name", "John");
await env.KV.put("user:123:email", "john@example.com");

// GOOD: Single coalesced object (hot key cache, single read, fewer ops)
await env.USERS.put("user:123:profile", JSON.stringify({
  name: "John", email: "john@example.com", role: "admin"
}));
// Trade-off: harder to update individual fields
```

## Hierarchical Keys

```typescript
// Use prefixes for organization and list queries
// "user:123:profile", "user:123:settings", "cache:api:users", "session:abc-def"
const userKeys = await env.MY_KV.list({ prefix: "user:123:" });
```
