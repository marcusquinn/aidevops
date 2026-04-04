<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

## Common API Categories

### Zone Management

```typescript
const zones = await client.zones.list({ account: { id: 'account-id' }, status: 'active' });
const zone = await client.zones.create({ account: { id: 'account-id' }, name: 'example.com', type: 'full' });
await client.zones.edit('zone-id', { paused: false });
await client.zones.delete('zone-id');
```

### DNS Management

```typescript
// Create record
await client.dns.records.create({
  zone_id: 'zone-id',
  type: 'A', // A | AAAA | CNAME | TXT | MX | SRV
  name: 'subdomain.example.com',
  content: '192.0.2.1',
  ttl: 1, // 1 = auto
  proxied: true,
});

// List/update/delete
const records = await client.dns.records.list({ zone_id: 'zone-id', type: 'A' });
await client.dns.records.edit('record-id', { zone_id: 'zone-id', content: '192.0.2.2' });
await client.dns.records.delete('record-id', { zone_id: 'zone-id' });
```

### Workers & KV

```typescript
// KV namespace operations
await env.MY_KV.put('key', 'value', { expirationTtl: 3600 });
const value = await env.MY_KV.get('key');
await env.MY_KV.delete('key');
const list = await env.MY_KV.list({ prefix: 'user:', limit: 100 });
```

### R2 Storage

```typescript
await env.MY_BUCKET.put('object-key', body, { httpMetadata: { contentType: 'image/png' } });
const obj = await env.MY_BUCKET.get('object-key');
await env.MY_BUCKET.delete('object-key');
const listed = await env.MY_BUCKET.list({ prefix: 'uploads/', limit: 50 });
```

### Pagination

```typescript
// Auto-paginate with for-await
for await (const zone of client.zones.list()) {
  console.log(zone.name);
}

// Manual pagination
let page = await client.zones.list({ per_page: 50 });
while (page.result.length > 0) {
  // process page.result
  if (!page.result_info?.next_page) break;
  page = await page.getNextPage();
}
```
