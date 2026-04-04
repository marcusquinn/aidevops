<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cache Reserve Patterns

## Best Practices

### 1. Always Enable Tiered Cache

Cache Reserve is designed for use **with** Tiered Cache. Enable both: Dashboard → Caching → Tiered Cache → Smart Tiered Cache Topology, then enable Cache Reserve.

### 2. Set Appropriate Cache-Control Headers

```typescript
// Origin response headers for Cache Reserve eligibility
const originHeaders = {
  'Cache-Control': 'public, max-age=86400', // min 10 hours (36000s)
  'Content-Length': '1024000',              // required for eligibility
  'Cache-Tag': 'images,product-123',        // optional: for purging
  'ETag': '"abc123"',                       // optional: revalidation
  // Avoid: 'Set-Cookie' (prevents caching), 'Vary: *' (not compatible)
};
```

### 3. Use Cache Rules for Fine-Grained Control

```typescript
const cacheRules = [
  {
    description: 'Long-term cache for immutable assets',
    expression: '(http.request.uri.path matches "^/static/.*\\.[a-f0-9]{8}\\.")',
    action_parameters: {
      cache_reserve: { eligible: true },
      edge_ttl: { mode: 'override_origin', default: 2592000 }, // 30 days
      cache: true
    }
  },
  {
    description: 'Moderate cache for regular images',
    expression: '(http.request.uri.path matches "\\.(jpg|png|webp)$")',
    action_parameters: {
      cache_reserve: { eligible: true },
      edge_ttl: { mode: 'override_origin', default: 86400 }, // 24 hours
      cache: true
    }
  },
  {
    description: 'Exclude API from Cache Reserve',
    expression: '(http.request.uri.path matches "^/api/")',
    action_parameters: { cache_reserve: { eligible: false }, cache: false }
  }
];
```

### 4. Ensuring Cache Reserve Eligibility in Workers

```typescript
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const response = await fetch(request);
    if (!response.ok) return response;

    const headers = new Headers(response.headers);
    headers.set('Cache-Control', 'public, max-age=36000'); // min 10 hours
    headers.delete('Set-Cookie');

    if (!headers.has('Content-Length')) {
      const blob = await response.blob();
      headers.set('Content-Length', blob.size.toString());
      return new Response(blob, { status: response.status, headers });
    }

    return new Response(response.body, { status: response.status, headers });
  }
};
```

### 5. Hostname Best Practices

```typescript
// ✅ Keep the Worker's hostname — avoids unnecessary DNS lookups
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return await fetch(request);
  }
};

// ❌ Don't override hostname
const url = new URL(request.url);
url.hostname = 'different-host.com'; // causes DNS lookup, breaks caching
```

## Architecture Patterns

### Multi-Tier Caching + Immutable Assets

L1 (visitor) → L2 (region) → L3 (Cache Reserve) → Origin. Each miss backfills all upstream layers.

```typescript
// Immutable asset optimization: detect content-hashed filenames
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const isImmutable = /\.[a-f0-9]{8,}\.(js|css|jpg|png|woff2)$/.test(url.pathname);
    const response = await fetch(request);

    if (isImmutable) {
      const headers = new Headers(response.headers);
      headers.set('Cache-Control', 'public, max-age=31536000, immutable'); // 1 year
      return new Response(response.body, { status: response.status, headers });
    }

    return response;
  }
};
```

## Cost Optimization

Typical savings: 50–80% reduction in origin egress.
Origin cost (AWS): ~$0.09/GB vs Cache Reserve: $0.015/GB-month + $0.36/M reads.

| TTL | Effect |
|-----|--------|
| < 10 hours (36000s) | Not eligible |
| 24 hours (86400s) | Optimal — reduces rewrites |
| 30 days (2592000s) | Use cautiously for truly stable assets |

- Cache: images, media, fonts, archives
- Exclude: `/api/`, user-specific content, frequently changing JSON
- Note: Cache Reserve fetches uncompressed from origin; compresses for visitors

## See Also

- [Overview](./cache-reserve.md) - Core concepts, hierarchy, eligibility, setup
- [Gotchas](./cache-reserve-gotchas.md) - Common issues, troubleshooting, limits
