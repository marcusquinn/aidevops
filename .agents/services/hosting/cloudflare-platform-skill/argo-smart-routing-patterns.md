<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Argo Smart Routing — Patterns

## Integration with Tiered Cache

**Endpoint:** `PATCH /zones/{zone_id}/argo/tiered_caching`

**Benefits:** Argo optimizes edge-to-origin routing; Tiered Cache reduces origin requests via cache hierarchy. Combined: optimal network path + reduced origin load.

```typescript
async function enableArgoWithTieredCache(
  client: Cloudflare,
  zoneId: string
) {
  await client.argo.smartRouting.edit({ zone_id: zoneId, value: 'on' });
  await client.argo.tieredCaching.edit({ zone_id: zoneId, value: 'on' });
}
```

**Architecture Flow:**

```
Visitor → Edge Data Center (Lower-Tier)
         ↓ [Cache Miss]
         Upper-Tier Data Center
         ↓ [Cache Miss + Argo Smart Route]
         Origin Server
```

## Usage-Based Billing Management

Argo Smart Routing is billed per GB of traffic routed. Monitor and control costs:

```typescript
async function checkArgoStatus(client: Cloudflare, zoneId: string) {
  const status = await client.argo.smartRouting.get({ zone_id: zoneId });
  return status.value; // 'on' | 'off'
}

// Disable for non-production zones to control costs
async function disableArgoForStaging(client: Cloudflare, zoneId: string) {
  await client.argo.smartRouting.edit({
    zone_id: zoneId,
    value: 'off',
  });
}
```

**Cost control patterns:**
- Disable on dev/staging zones — enable only in production
- Monitor via Cloudflare Analytics (requires 500+ requests in 48h for detailed metrics)
- Set up billing alerts in the Cloudflare dashboard
