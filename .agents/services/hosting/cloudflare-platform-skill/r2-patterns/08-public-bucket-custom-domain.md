<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# R2 Pattern: Public Bucket with Custom Domain

Extends the streaming pattern with CORS and long-lived cache headers:

```typescript
const key = new URL(request.url).pathname.slice(1);
const object = await env.MY_BUCKET.get(key);
if (!object) return new Response('Not found', { status: 404 });

const headers = new Headers();
object.writeHttpMetadata(headers);
headers.set('etag', object.httpEtag);
headers.set('access-control-allow-origin', '*');
headers.set('cache-control', 'public, max-age=31536000, immutable');

return new Response(object.body, { headers });
```
