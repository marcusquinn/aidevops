# R2 Pattern: Upload with Validation

```typescript
const key = url.pathname.slice(1);
if (!key || key.includes('..')) return new Response('Invalid key', { status: 400 });

const object = await env.MY_BUCKET.put(key, request.body, {
  httpMetadata: { contentType: request.headers.get('content-type') || 'application/octet-stream' },
  customMetadata: { uploadedAt: new Date().toISOString(), ip: request.headers.get('cf-connecting-ip') || 'unknown' }
});

return Response.json({ key: object.key, size: object.size, etag: object.httpEtag });
```
