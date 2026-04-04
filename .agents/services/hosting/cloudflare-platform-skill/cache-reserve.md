<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudflare Cache Reserve

Persistent cache storage built on R2. Sits above tiered cache hierarchy; stores cacheable content for 30+ days to maximise cache hits and reduce origin egress.

## Cache Hierarchy

```text
Visitor → Lower-Tier Cache → Upper-Tier Cache → Cache Reserve (R2) → Origin
```

On edge eviction, Cache Reserve restores content to edge caches on next request. Retention: 30 days since last access (reset on each hit).

## Asset Eligibility

All criteria must be met:

- Cacheable per Cloudflare standard rules
- TTL ≥ 10 hours (36000s)
- `Content-Length` header present
- Original files only (not transformed images)

**Not eligible:** TTL < 10h, no `Content-Length`, image transformation variants, `Set-Cookie`, `Vary: *`, R2 public bucket assets on same zone, O2O requests.

## Setup

**Prerequisites:** Paid Cache Reserve plan; Tiered Cache strongly recommended.

Enable via Dashboard: `https://dash.cloudflare.com/caching/cache-reserve` → "Enable Storage Sync".

```bash
# Check status
curl -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/cache/cache_reserve" \
  -H "Authorization: Bearer $API_TOKEN"

# Enable
curl -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/cache/cache_reserve" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"value": "on"}'

# Verify asset cache status
curl -I https://example.com/asset.jpg | grep -i cache
```

## See Also

- [Patterns](./patterns.md) - Best practices and architecture patterns
- [Gotchas](./gotchas.md) - Common issues, troubleshooting, limits
