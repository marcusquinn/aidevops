# R2 Pattern: Streaming Large Files

```typescript
const object = await env.MY_BUCKET.get(key);
if (!object) return new Response('Not found', { status: 404 });

const headers = new Headers();
object.writeHttpMetadata(headers);
headers.set('etag', object.httpEtag);

return new Response(object.body, { headers });
```
