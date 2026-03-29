# Gotchas & Limits

## Limits

- **Max 8 tags per Worker**
- **Upload session JWT valid 1 hour**
- **Completion token valid 1 hour**
- **No limits on Workers per namespace** (unlike regular Workers)
- **User Workers run in untrusted mode** — no `request.cf` access, isolated from other customers, never share cache
- **Outbound Workers don't intercept DO/mTLS fetch** — plan accordingly for complete egress control
- **One namespace per environment** — not one per customer; namespace is the isolation boundary for an environment (prod/staging)

## Security

### Asset Isolation

Assets shared across namespace by hash. For strict isolation:

```typescript
const hash = sha256(accountId + fileContents).slice(0, 32);
```

Never expose upload JWTs to clients.

## Error Handling

### Worker Not Found

```typescript
try {
  const userWorker = env.DISPATCHER.get(name);
  return await userWorker.fetch(request);
} catch (e) {
  if (e.message.startsWith("Worker not found")) {
    return new Response("Worker not found", { status: 404 });
  }
  return new Response(e.message, { status: 500 });
}
```

### Limit Violations

```typescript
try {
  return await userWorker.fetch(request);
} catch (e) {
  if (e.message.includes("CPU time limit")) {
    env.ANALYTICS.writeDataPoint({
      indexes: [workerName],
      blobs: ["cpu_limit_exceeded"],
    });
    return new Response("CPU limit exceeded", { status: 429 });
  }
  throw e;
}
```

## Troubleshooting

### Hostname Routing

- Use `*/*` wildcard route — avoids DNS proxy issues regardless of orange-to-orange proxy settings

### Binding Preservation

- Use `keep_bindings` on update — existing bindings are lost without it

### Tag Filtering

- URL encode tags: `tags=production%3Ayes`
- Avoid special chars: `,` and `&`

### Deploy Failures

- ES modules require multipart form upload
- Must specify `main_module` in metadata
- File type: `application/javascript+module`

### Static Assets

- Hash must be first 16 bytes (32 hex chars) of SHA-256
- Upload must happen within 1 hour of session creation
- Deploy must happen within 1 hour of upload completion
- Base64 encode file contents for upload

## TypeScript Types

```typescript
interface Env {
  DISPATCHER: DispatchNamespace;
  ROUTING_KV: KVNamespace;
  CUSTOMERS_KV: KVNamespace;
  ANALYTICS: AnalyticsEngineDataset;
}

interface DispatchNamespace {
  get(
    name: string,
    options?: Record<string, unknown>,
    config?: {
      limits?: {
        cpuMs?: number;
        subRequests?: number;
      };
      outbound?: Record<string, unknown>;
    }
  ): Fetcher;
}

interface Fetcher {
  fetch(request: Request): Promise<Response>;
}
```

See [README.md](./README.md), [patterns.md](./patterns.md)
