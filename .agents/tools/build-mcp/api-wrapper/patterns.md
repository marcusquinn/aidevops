---
description: Common API patterns for MCP tool implementations
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Common API Patterns

Reference patterns for `api-wrapper.md`. All examples assume `apiRequest` and `toolResult`/`toolError` helpers from the main template.

## Pagination (cursor-based)

```typescript
server.tool('list_paginated', {
  cursor: z.string().optional().describe('Pagination cursor'),
  limit: z.number().optional().default(50).describe('Items per page'),
}, async (args) => {
  try {
    const params = new URLSearchParams({ limit: String(args.limit) });
    if (args.cursor) params.set('cursor', args.cursor);
    const data = await apiRequest(`/items?${params}`);
    return toolResult({
      items: data.items,
      nextCursor: data.next_cursor,
      hasMore: !!data.next_cursor,
    });
  } catch (e) { return toolError(e); }
});
```

## Search

```typescript
server.tool('search', {
  query: z.string().describe('Search query'),
  fields: z.array(z.string()).optional().describe('Fields to search'),
  sort: z.enum(['relevance', 'date', 'name']).optional().default('relevance'),
}, async (args) => {
  try {
    return toolResult(await apiRequest('/search', 'POST', {
      q: args.query,
      fields: args.fields,
      sort: args.sort,
    }));
  } catch (e) { return toolError(e); }
});
```

## Batch Operations

```typescript
server.tool('batch_update', {
  ids: z.array(z.string()).describe('Item IDs to update'),
  updates: z.object({
    status: z.string().optional(),
    tags: z.array(z.string()).optional(),
  }).describe('Updates to apply'),
}, async (args) => {
  const results = await Promise.all(
    args.ids.map(id =>
      apiRequest(`/items/${id}`, 'PUT', args.updates)
        .then(data => ({ id, success: true, data }))
        .catch(error => ({ id, success: false, error: String(error) }))
    )
  );
  return toolResult(results);
});
```

## File Upload (base64)

```typescript
server.tool('upload_file', {
  filename: z.string().describe('File name'),
  content: z.string().describe('Base64 encoded file content'),
  mimeType: z.string().optional().default('application/octet-stream'),
}, async (args) => {
  try {
    const response = await fetch(`${API_BASE}/upload`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${API_KEY}`,
        'Content-Type': args.mimeType,
        'X-Filename': args.filename,
      },
      body: Buffer.from(args.content, 'base64'),
    });
    return toolResult(await response.json());
  } catch (e) { return toolError(e); }
});
```
