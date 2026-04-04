<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudflare Workers Smart Placement

Runs Workers closer to backend infrastructure instead of end users — reduces latency when backend round-trips dominate over user-to-edge distance.

## When to Enable

**Enable:** multiple backend round-trips, geographically concentrated backend, backend latency dominates (APIs, data aggregation, SSR with DB calls).

**Do NOT enable:** static/cached content, no backend calls, pure edge logic (auth, redirects, transforms), no fetch handlers.

**Requirements:** Wrangler 2.20.0+, consistent traffic from multiple global locations. Affects fetch handlers only (not RPC methods or named entrypoints). All plans. Analysis ≤15 min; runs at edge until complete.

## Architecture: Frontend/Backend Split

```text
User → Frontend Worker (edge, close to user)
         ↓ Service Binding
       Backend Worker (Smart Placement, close to DB/API)
         ↓
       Database/Backend Service
```

Split full-stack apps — monolithic Workers with Smart Placement degrade frontend latency.

## Quick Start

```toml
# wrangler.toml
[placement]
mode = "smart"
hint = "wnam"  # Optional: West North America
```

Deploy and wait up to 15 min for analysis.

## Placement Status

```typescript
type PlacementStatus =
  | undefined  // Not yet analyzed
  | 'SUCCESS'  // Optimized
  | 'INSUFFICIENT_INVOCATIONS'  // Not enough traffic
  | 'UNSUPPORTED_APPLICATION';  // Made Worker slower (reverted)
```

1% of requests always route without optimization (baseline comparison) — expected behaviour.

## Status Check

```bash
# Check placement status
curl -H "Authorization: Bearer $TOKEN" \
  https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/workers/services/$WORKER_NAME \
  | jq .result.placement_status

# Monitor with placement header
wrangler tail your-worker-name --header cf-placement
```

## See Also

- [patterns.md](./patterns.md) — frontend/backend split, database workers, SSR, API gateway
- [gotchas.md](./gotchas.md) — troubleshooting INSUFFICIENT_INVOCATIONS, performance issues
- [workers](../workers/) — Worker runtime and fetch handlers
- [d1](../d1/) — D1 database (benefits from Smart Placement)
- [durable-objects](../durable-objects/) — Durable Objects with backend logic
- [bindings](../bindings/) — Service bindings for frontend/backend split
