<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

## Common Anti-Patterns

### Hardcoding Credentials

```typescript
const apiKey = 'sk_live_abc123';
```

Use secrets instead:

```bash
npx wrangler secret put API_KEY
```

### Using REST API from Worker

```typescript
await fetch('https://api.cloudflare.com/client/v4/accounts/.../kv/...');
```

Use bindings instead:

```typescript
await env.MY_KV.get('key');
```

### Polling KV/D1 for Changes

```typescript
setInterval(() => {
  const config = await env.KV.get('config');
}, 1000);
```

Use Durable Objects for real-time state instead.

### Storing Large Data in env.vars

```typescript
{ "vars": { "HUGE_CONFIG": "..." } } // Max 5KB per var
```

Use KV/R2 for large data instead.
