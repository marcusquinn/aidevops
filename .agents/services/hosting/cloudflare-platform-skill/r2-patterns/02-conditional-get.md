# R2 Pattern: Conditional GET (304 Not Modified)

```typescript
const ifNoneMatch = request.headers.get('if-none-match');
const object = await env.MY_BUCKET.get(key, {
  onlyIf: { etagDoesNotMatch: ifNoneMatch?.replace(/"/g, '') || '' }
});

if (!object) return new Response('Not found', { status: 404 });
if (!object.body) return new Response(null, { status: 304, headers: { 'etag': object.httpEtag } });

return new Response(object.body, { headers: { 'etag': object.httpEtag } });
```
