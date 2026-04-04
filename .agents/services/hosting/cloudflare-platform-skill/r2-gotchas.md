<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# R2 Gotchas & Troubleshooting

## Key Validation

Unsanitized keys allow path traversal:

```typescript
// DANGEROUS
const key = url.pathname.slice(1); // could be ../../../etc/passwd

// SAFE
if (!key || key.includes('..') || key.startsWith('/')) {
  return new Response('Invalid key', { status: 400 });
}
```

## List Truncation

`include` with metadata may return fewer objects per page. Paginate via `truncated`, not `objects.length`:

```typescript
// WRONG — breaks when include reduces page size
while (listed.objects.length < options.limit) { ... }

// CORRECT
while (listed.truncated) {
  const next = await env.MY_BUCKET.list({ cursor: listed.cursor });
}
```

Requires `compatibility_date >= 2022-08-04` or `r2_list_honor_include` flag.

## Conditional Operations

Precondition failure returns the object WITHOUT body (not null):

```typescript
const object = await env.MY_BUCKET.get(key, {
  onlyIf: { etagMatches: '"wrong"' }
});
if (!object) return new Response('Not found', { status: 404 });
if (!object.body) return new Response(null, { status: 304 }); // precondition failed
```

## ETag Format

Use `httpEtag` (RFC-quoted) in headers, not `etag` (unquoted):

```typescript
headers.set('etag', object.httpEtag); // not object.etag
```

## Checksum Limits

Only ONE checksum algorithm per PUT:

```typescript
await env.MY_BUCKET.put(key, data, { sha256: hash }); // not { md5: h1, sha256: h2 }
```

## Multipart Requirements

- All parts must be uniform size (except last)
- Part numbers start at 1 (not 0)
- Uncompleted uploads auto-abort after 7 days
- `resumeMultipartUpload` doesn't validate uploadId existence

## Storage Class (InfrequentAccess)

- 30-day minimum billing (even if deleted early)
- Can't transition IA → Standard via lifecycle (use S3 CopyObject)
- Retrieval fees apply for IA reads

## Limits

| Limit | Value |
|-------|-------|
| Object size | 5 TB |
| Multipart part count | 10,000 |
| Batch delete | 1,000 keys |
| List limit | 1,000 per request |
| Key size | 1,024 bytes |
| Custom metadata | 2 KB per object |
