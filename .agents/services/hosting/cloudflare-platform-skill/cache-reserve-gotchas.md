<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cache Reserve Gotchas

## Eligibility Requirements

An asset enters Cache Reserve only if all hold:

- Paid Cache Reserve plan active
- Tiered Cache enabled (strongly recommended)
- Asset cacheable per standard rules
- TTL >= 10 hours (36000s) — `Cache-Control: public, max-age=36000`
- `Content-Length` header present
- No `Set-Cookie` header (or `private` directive)
- No `Vary: *` (use `Vary: Accept-Encoding` instead)
- Not an image transformation variant

## Assets Not Being Cached

Run these checks first:

```bash
# Check Cache Reserve status and asset eligibility
curl -I https://example.com/asset.jpg | grep -i cache
curl -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/cache/cache_reserve" \
  -H "Authorization: Bearer $API_TOKEN" | jq
```

Common failures after checking eligibility above:
- `cf-cache-status: MISS` — check TTL (must be ≥36000s), `Content-Length` header, and blocking headers
- Review Cloudflare Trace output and Logpush `CacheReserveUsed` field

Typical fixes:

```typescript
// Ensure minimum TTL (10+ hours)
response.headers.set('Cache-Control', 'public, max-age=36000');

// Or via Cache Rule:
const rule = {
  action_parameters: {
    edge_ttl: { mode: 'override_origin', default: 36000 }
  }
};

// Add Content-Length
response.headers.set('Content-Length', bodySize.toString());

// Remove blocking headers
response.headers.delete('Set-Cookie');
response.headers.set('Vary', 'Accept-Encoding'); // Not *
```

## High Class A Operations Costs

Frequent misses, short TTLs, and repeated revalidation increase Class A charges. For stable content, raise TTLs and use Tiered Cache to reduce direct Cache Reserve misses:

```typescript
response.headers.set('Cache-Control', 'public, max-age=86400, stale-while-revalidate=86400');
```

## Purge Behaviour

| Method | Cache Reserve | Edge Cache | Cost |
|--------|--------------|------------|------|
| By URL | Immediately removed | Immediately removed | Free |
| By Tag | Revalidation triggered (NOT removed) | Immediately removed | Storage costs continue until TTL |

Use purge by URL for immediate removal. Purge by tag triggers revalidation but does not remove stored content. For complete removal, disable Cache Reserve, then clear it:

```typescript
await purgeByURL(['https://example.com/asset.jpg']);

// Complete removal:
await disableCacheReserve(zoneId, token);
await clearAllCacheReserve(zoneId, token);
```

## Clearing Cache Reserve

Error: `"Cache Reserve must be OFF before clearing data"`

```typescript
const clearProcess = async (zoneId: string, token: string) => {
  const status = await getCacheReserveStatus(zoneId, token);
  if (status.result.value !== 'off') {
    await disableCacheReserve(zoneId, token);
  }
  await new Promise(resolve => setTimeout(resolve, 5000)); // propagation delay
  await clearAllCacheReserve(zoneId, token);

  // Monitor progress — can take up to 24 hours
  let clearStatus;
  do {
    await new Promise(resolve => setTimeout(resolve, 60000));
    clearStatus = await getClearStatus(zoneId, token);
  } while (clearStatus.result.state === 'In-progress');
};
```

## Limits

| Setting | Value |
|---------|-------|
| Min TTL | 36000s (10 hours) |
| Default retention | 2592000s (30 days) |
| Max file size | Same as R2 limits |
| Purge/clear time | Up to 24 hours |

API endpoints:

| Action | Method + Path |
|--------|--------------|
| Status | `GET /zones/:zone_id/cache/cache_reserve` |
| Enable/Disable | `PATCH /zones/:zone_id/cache/cache_reserve` |
| Clear | `POST /zones/:zone_id/cache/cache_reserve_clear` |
| Clear status | `GET /zones/:zone_id/cache/cache_reserve_clear` |
| Purge | `POST /zones/:zone_id/purge_cache` |
| Cache Rules | `PUT /zones/:zone_id/rulesets/phases/http_request_cache_settings/entrypoint` |

## Resources

- [Cache Reserve docs](https://developers.cloudflare.com/cache/advanced-configuration/cache-reserve/)
- [API reference](https://developers.cloudflare.com/api/resources/cache/subresources/cache_reserve/)
- [Cache Rules](https://developers.cloudflare.com/cache/how-to/cache-rules/)
- [Workers Cache API](https://developers.cloudflare.com/workers/runtime-apis/cache/)
- [R2 docs](https://developers.cloudflare.com/r2/)
- [Smart Shield](https://developers.cloudflare.com/smart-shield/)
- [Tiered Cache](https://developers.cloudflare.com/cache/how-to/tiered-cache/)
- [Cache Reserve overview](./cache-reserve.md) — overview and core concepts
- [Cache Reserve patterns](./cache-reserve-patterns.md) — best practices and optimization
