# Gotchas

See [queues.md](./queues.md), [queues-patterns.md](./queues-patterns.md).

## Delivery Semantics

Queues are at-least-once; no ordering guarantee. Design for idempotency — ack only after durable success.

```typescript
const processed = await env.PROCESSED_KV.get(msg.id);
if (processed) { msg.ack(); continue; }
await processMessage(msg.body);
await env.PROCESSED_KV.put(msg.id, '1', { expirationTtl: 86400 });
msg.ack();
```

## Content Type

`json` is dashboard-visible and works with pull consumers. `v8` is not decodable in pull consumers or the dashboard.

```typescript
await env.MY_QUEUE.send(data, { contentType: 'json' }); // always use json for pull
```

## Retries and CPU Budget

Handler exits without `ack()` or `retry()` → Cloudflare retries per queue policy. Default CPU budget is 30s; raise for heavier work.

```typescript
async queue(batch: MessageBatch): Promise<void> {
  for (const msg of batch.messages) {
    try {
      await processMessage(msg.body);
      msg.ack();
    } catch (error) {
      msg.retry({ delaySeconds: 600 }); // omit to auto-retry
    }
  }
}
```

```jsonc
// wrangler.toml [limits]
{ "limits": { "cpu_ms": 300000 } } // 5 minutes
```

Log failures with enough context to replay or diagnose. Configure a DLQ for permanent failures.

## Cost and Throughput

Each message = 3 ops (write + read + delete). Retries add reads. Cost beyond free tier: `((messages × 3) - 1M) / 1M × $0.40`. Keep messages <64 KB (charged per 64 KB chunk).

```jsonc
// wrangler.toml [queues.consumers]
{ "max_batch_size": 100, "max_batch_timeout": 30 }
```

Use `waitUntil()` for non-blocking sends. Batch sends when possible.

| Limit | Value |
|-------|-------|
| Max queues | 10,000 |
| Message size | 128 KB |
| Batch size (consumer) | 100 messages |
| Batch size (sendBatch) | 100 msgs/256 KB |
| Throughput | 5,000 msgs/sec/queue |
| Retention | 4-14 days |
| Max backlog | 25 GB |
| Max delay | 12 hours (43,200s) |
| Max retries | 100 |

## Troubleshooting

### Message not delivered

```bash
wrangler queues list                                          # Check queue paused
wrangler queues consumer worker remove my-queue my-worker    # Verify consumer
wrangler queues consumer add my-queue my-worker
wrangler tail my-worker                                       # Check logs
```

### High DLQ rate

- Review consumer error logs.
- Check external dependency availability.
- Verify message format matches expectations.
- Increase retry delay: `"retry_delay": 300`.
