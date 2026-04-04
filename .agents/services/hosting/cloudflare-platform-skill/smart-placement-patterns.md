<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Smart Placement Patterns

## Backend Worker with Database Access

```typescript
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const user = await env.DATABASE.prepare('SELECT * FROM users WHERE id = ?').bind(userId).first();
    const orders = await env.DATABASE.prepare('SELECT * FROM orders WHERE user_id = ?').bind(userId).all();
    return Response.json({ user, orders });
  }
};
```

```toml
name = "backend-api"; [placement]; mode = "smart"; [[d1_databases]]; binding = "DATABASE"
```

## Frontend + Backend Split

**Frontend (no Smart Placement):** edge — fast user response. **Backend (Smart Placement):** close to database.

```typescript
// Frontend
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (new URL(request.url).pathname.startsWith('/api/')) return env.BACKEND.fetch(request);
    return env.ASSETS.fetch(request);
  }
};

// Backend
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return Response.json(await env.DATABASE.prepare('SELECT * FROM table').all());
  }
};
```

## External API Integration

```typescript
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const apiUrl = 'https://api.partner.com';
    const headers = { 'Authorization': `Bearer ${env.API_KEY}` };
    const [profile, transactions] = await Promise.all([
      fetch(`${apiUrl}/profile`, { headers }),
      fetch(`${apiUrl}/transactions`, { headers })
    ]);
    return Response.json({ profile: await profile.json(), transactions: await transactions.json() });
  }
};
```

```toml
[placement]; mode = "smart"; hint = "enam"  # hint if API region is known (e.g. East North America)
```

## Multi-Service Aggregation

```typescript
export default {
  async fetch(request: Request, env: Env) {
    const [orders, inventory, shipping] = await Promise.all([
      fetch('https://orders.internal.api'), fetch('https://inventory.internal.api'), fetch('https://shipping.internal.api')
    ]);
    return Response.json({ orders: await orders.json(), inventory: await inventory.json(), shipping: await shipping.json() });
  }
};
```

## SSR with Backend Data

```typescript
// Frontend (edge)
export default {
  async fetch(request: Request, env: Env) {
    const data = await env.BACKEND.fetch('/api/page-data');
    return new Response(renderPage(await data.json()), { headers: { 'Content-Type': 'text/html' } });
  }
};

// Backend (Smart Placement)
export default {
  async fetch(request: Request, env: Env) {
    return Response.json(await env.DATABASE.prepare('SELECT * FROM pages WHERE id = ?').bind(pageId).first());
  }
};
```

## API Gateway

```typescript
// Gateway (edge)
export default {
  async fetch(request: Request, env: Env) {
    if (!request.headers.get('Authorization')) return new Response('Unauthorized', { status: 401 });
    return env.BACKEND_API.fetch(request);
  }
};

// Backend (Smart Placement)
export default {
  async fetch(request: Request, env: Env) {
    return Response.json(await performDatabaseOperations(env.DATABASE));
  }
};
```

## Best Practices

1. **Split full-stack apps:** frontend at edge, backend with Smart Placement
2. **Use Service Bindings** to connect frontend/backend Workers
3. **Enable for backend logic:** APIs, data aggregation, server-side processing
4. **Don't enable for pure edge work:** auth checks, redirects, static content
5. **Use placement hints** if you know the backend/API region
6. **Wait 15+ min** after enabling before reading placement metrics
7. **Verify `SUCCESS` status** via API after deploy
8. **Monitor request duration** before/after; combine with caching

## Anti-Patterns

❌ Smart Placement on static content Workers  
❌ Monolithic full-stack Worker with Smart Placement (degrades frontend latency)  
❌ Not verifying placement status after deploy
