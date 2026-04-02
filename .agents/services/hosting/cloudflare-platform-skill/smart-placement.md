# Cloudflare Workers Smart Placement

Optimizes request duration by running Workers closer to backend infrastructure when backend latency dominates.

## Quick Start

```toml
# wrangler.toml
[placement]
mode = "smart"
hint = "wnam"  # Optional: e.g., West North America
```

Deploy and wait 15 min for analysis.

## When to Enable

- **Enable for:** Multiple backend round trips, geographically concentrated infrastructure, backend-heavy logic (APIs, data aggregation, SSR with DB calls).
- **Do NOT enable for:** Static/cached content, pure edge logic (auth, redirects, transforms), Workers without fetch handlers.

## Architecture: Frontend/Backend Split

```text
User → Frontend Worker (edge, close to user)
         ↓ Service Binding
       Backend Worker (Smart Placement, close to DB/API)
         ↓
       Database/Backend Service
```

Split full-stack apps — monolithic Workers with Smart Placement degrade frontend latency.

## Requirements & Status

- **Requirements:** Wrangler 2.20.0+, consistent global traffic. Only affects fetch handlers.
- **Analysis:** Up to 15 min after enabling; Worker runs at edge during analysis.
- **Baseline:** 1% of requests always route without optimization for comparison.

```typescript
type PlacementStatus =
  | undefined  // Not yet analyzed
  | 'SUCCESS'  // Optimized
  | 'INSUFFICIENT_INVOCATIONS'  // Not enough traffic
  | 'UNSUPPORTED_APPLICATION';  // Made Worker slower (reverted)
```

## CLI

```bash
# Check placement status
curl -H "Authorization: Bearer $TOKEN" \
  https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/workers/services/$WORKER_NAME \
  | jq .result.placement_status

# Monitor with placement header
wrangler tail your-worker-name --header cf-placement
```

## See Also

- [patterns.md](./patterns.md) — split architecture, DB workers, SSR, API gateway
- [gotchas.md](./gotchas.md) — troubleshooting performance and invocations
- [workers](../workers/)
- [d1](../d1/)
- [durable-objects](../durable-objects/)
- [bindings](../bindings/)

