# Cache Reserve Gotchas

## Eligibility Requirements

All must hold for an asset to enter Cache Reserve:

- Paid Cache Reserve plan active
- Tiered Cache enabled (strongly recommended)
- Asset cacheable per standard rules
- TTL >= 10 hours (36000s) — `Cache-Control: public, max-age=36000`
- `Content-Length` header present
- No `Set-Cookie` header (or `private` directive)
- No `Vary: *` (use `Vary: Accept-Encoding` instead)
- Not an image transformation variant

## Assets Not Being Cached

**Diagnostics:**

- Check `cf-cache-status` header: `curl -I https://example.com/asset.jpg`
- Verify eligibility requirements above
- Review Cloudflare Trace output and Logpush `CacheReserveUsed` field

**Fixes:**

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

**Cause**: Frequent cache misses, short TTLs, or frequent revalidation.

```typescript
// Increase TTL for stable content
response.headers.set('Cache-Control', 'public, max-age=86400, stale-while-revalidate=86400');

// Enable Tiered Cache — reduces direct Cache Reserve misses
```

## Purge Behaviour

| Method | Cache Reserve | Edge Cache | Cost |
|--------|--------------|------------|------|
| By URL | Immediately removed | Immediately removed | Free |
| By Tag | Revalidation triggered (NOT removed) | Immediately removed | Storage costs continue until TTL |

Use purge by URL for immediate removal. For complete removal, disable + clear:

```typescript
await purgeByURL(['https://example.com/asset.jpg']);

// Complete removal:
await disableCacheReserve(zoneId, token);
await clearAllCacheReserve(zoneId, token);
```

## Clearing Cache Reserve

**Error**: `"Cache Reserve must be OFF before clearing data"`

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

## Troubleshooting

```bash
# Check Cache Reserve status
curl -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/cache/cache_reserve" \
  -H "Authorization: Bearer $API_TOKEN" | jq

# Check asset cache status
curl -I https://example.com/asset.jpg | grep -i cache
```

**Header indicators:**

- Eligible: `cf-cache-status: HIT`, `max-age >= 36000`, `content-length` present
- Not eligible: fails any requirement in Eligibility Requirements above

## Limits

| Setting | Value |
|---------|-------|
| Min TTL | 36000s (10 hours) |
| Default retention | 2592000s (30 days) |
| Max file size | Same as R2 limits |
| Purge/clear time | Up to 24 hours |

**API endpoints:**

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
- [README](./README.md) — overview and core concepts
- [Patterns](./patterns.md) — best practices and optimization
