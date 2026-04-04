<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Gotchas & Debugging

## Timeouts

- **Step**: 10 min/attempt default. CPU: 30s default, 5min max (`limits.cpu_ms = 300_000` in wrangler.toml)
- **waitForEvent**: 24h default, 365d max. **Throws on timeout** — always wrap in try-catch

```typescript
await step.do('long op', {timeout: '30 minutes'}, async () => { /* ... */ });

try {
  const event = await step.waitForEvent('wait', { type: 'approval', timeout: '1h' });
} catch (e) { /* Timeout - proceed with default */ }
```

## Limits

| Limit | Free | Paid |
|-------|------|------|
| CPU per step | 10ms | 30s (default), 5min (max) |
| Step state | 1 MiB | 1 MiB |
| Instance state | 100 MB | 1 GB |
| Steps per workflow | 1,024 | 1,024 |
| Executions/day | 100k | Unlimited |
| Concurrent instances | 25 | 10k |
| State retention | 3d | 30d |

`step.sleep()` doesn't count toward step limit.

## Debugging

```typescript
// Logs: inside steps = logged once; outside steps = may duplicate on restart
await step.do('process', async () => {
  console.log('Logged once per successful step');
  return result;
});
```

```bash
# Instance status via CLI
npx wrangler workflows instances describe my-workflow instance-id
```

```typescript
// Instance status via API
const status = await (await env.MY_WORKFLOW.get('instance-id')).status();
// queued | running | paused | errored | terminated | complete | waiting | waitingForPause | unknown
```

## Common Pitfalls

**Non-deterministic names/conditionals** — step names are cache keys; non-deterministic values break replay:

```typescript
// ❌ await step.do(`step-${Date.now()}`, ...)
// ✅ await step.do(`step-${event.instanceId}`, ...)

// ❌ if (Date.now() > deadline) { await step.do(...) }
// ✅ const isLate = await step.do('check', async () => Date.now() > deadline);
//    if (isLate) { await step.do(...) }
```

**State in variables** — local vars lost on hibernation; persist via step returns:

```typescript
// ❌ let total = 0; await step.do('s1', async () => { total += 10; });
// ✅ const total = await step.do('s1', async () => 10);
```

**Large step returns** — step state capped at 1 MiB; store in R2/KV, return refs:

```typescript
// ❌ return await fetchHugeDataset(); // 5 MiB
// ✅ Store in R2, return { key }
```

**Idempotency ignored** — steps retry on failure; side effects must be idempotent:

```typescript
// ❌ await step.do('charge', async () => await chargeCustomer(...));
// ✅ Check if already charged first; use NonRetryableError for permanent failures
```

**Instance ID collision** — IDs must be unique within retention window:

```typescript
// ❌ await env.MY_WORKFLOW.create({ id: userId, params: {} });
// ✅ await env.MY_WORKFLOW.create({ id: `${userId}-${Date.now()}`, params: {} });
```

**Missing await** — unawaited steps are fire-and-forget:

```typescript
// ❌ step.do('task', ...);
// ✅ await step.do('task', ...);
```

## Pricing

| Metric | Free | Paid |
|--------|------|------|
| Requests | 100k/day | 10M/mo + $0.30/M |
| CPU time | 10ms/invoke | 30M CPU-ms/mo + $0.02/M CPU-ms |
| Storage | 1 GB | 1 GB/mo + $0.20/GB-mo |

Storage includes all instances (running/errored/sleeping/completed). Retention: 3d (Free), 30d (Paid).

## References

[Docs](https://developers.cloudflare.com/workflows/) | [Guide](https://developers.cloudflare.com/workflows/get-started/guide/) | [Workers API](https://developers.cloudflare.com/workflows/build/workers-api/) | [REST API](https://developers.cloudflare.com/api/resources/workflows/) | [Examples](https://developers.cloudflare.com/workflows/examples/) | [Limits](https://developers.cloudflare.com/workflows/reference/limits/) | [Pricing](https://developers.cloudflare.com/workflows/reference/pricing/)

See: [workflows.md](./workflows.md), [workflows-patterns.md](./workflows-patterns.md)
