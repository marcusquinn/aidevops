# Cloudflare Workers Analytics Engine Reference

Expert guidance for implementing unlimited-cardinality analytics at scale using Cloudflare Workers Analytics Engine.

## What is Analytics Engine?

Time-series analytics database designed for high-cardinality data (millions of unique dimensions). Write data points from Workers, query via SQL API. Use for:
- Custom user-facing analytics dashboards
- Usage-based billing & metering
- Per-customer/per-feature monitoring
- High-frequency instrumentation without performance impact

**Key Capability:** Track metrics with unlimited unique values (e.g., millions of user IDs, API keys) without performance degradation.

## Core Concepts

| Concept | Description | Example |
|---------|-------------|---------|
| **Dataset** | Logical table for related metrics | `api_requests`, `user_events` |
| **Data Point** | Single measurement with timestamp | One API request's metrics |
| **Blobs** | String dimensions (max 20) | endpoint, method, status, user_id |
| **Doubles** | Numeric values (max 20) | latency_ms, request_count, bytes |
| **Indexes** | Filtered blobs for efficient queries | customer_id, api_key |

## Reading Order

| Task | Start Here | Then Read |
|------|------------|-----------|
| **First-time setup** | [configuration.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/analytics-engine/configuration.md) → [api.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/analytics-engine/api.md) → [patterns.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/analytics-engine/patterns.md) | |
| **Writing data** | [api.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/analytics-engine/api.md) → [gotchas.md](analytics-engine-gotchas.md) (sampling) | |
| **Querying data** | [api.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/analytics-engine/api.md) (SQL API) → [patterns.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/analytics-engine/patterns.md) (examples) | |
| **Debugging** | [gotchas.md](analytics-engine-gotchas.md) → [api.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/analytics-engine/api.md) (limits) | |
| **Optimization** | [patterns.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/analytics-engine/patterns.md) (anti-patterns) → [gotchas.md](analytics-engine-gotchas.md) | |

## When to Use Analytics Engine

```text
Need to track metrics? → Yes
  ↓
Millions of unique dimension values? → Yes
    ↓
  Need real-time queries? → Yes
      ↓
    Use Analytics Engine ✓

Alternative scenarios:
- Low cardinality (<10k unique values) → Workers Analytics (free tier)
- Complex joins/relations → D1 Database
- Logs/debugging → Tail Workers (logpush)
- External tools → Send to external analytics (Datadog, etc.)
```

## Quick Start

1. Add binding to `wrangler.jsonc`:

```jsonc
{
  "analytics_engine_datasets": [
    { "binding": "ANALYTICS", "dataset": "my_events" }
  ]
}
```

2. Write data points (fire-and-forget, no await):

```typescript
env.ANALYTICS.writeDataPoint({
  blobs: ["/api/users", "GET", "200"],
  doubles: [145.2, 1],  // latency_ms, count
  indexes: [customerId]
});
```

3. Query via SQL API (HTTP):

```sql
SELECT blob1, SUM(double2) AS total_requests
FROM my_events
WHERE index1 = 'customer_123'
  AND timestamp >= NOW() - INTERVAL '7' DAY
GROUP BY blob1
ORDER BY total_requests DESC
```

## In This Reference

- **[configuration.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/analytics-engine/configuration.md)** - Setup, bindings, TypeScript types, limits
- **[api.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/analytics-engine/api.md)** - `writeDataPoint()`, SQL API, query syntax
- **[patterns.md](https://github.com/cloudflare/skills/blob/41e0d19858946d18af9ee2c2feebbe2e11d829ff/skills/cloudflare/references/analytics-engine/patterns.md)** - Use cases, examples, anti-patterns
- **[gotchas.md](analytics-engine-gotchas.md)** - Sampling, index selection, troubleshooting

## See Also

- [Cloudflare Analytics Engine Docs](https://developers.cloudflare.com/analytics/analytics-engine/index.md)
- [GraphQL Analytics API Reference](../graphql-api/) - Query built-in Cloudflare analytics (HTTP, Workers, DNS, Firewall, etc.)
- [Observability Reference](../observability/) - Workers Logs, Traces, and real-time debugging
