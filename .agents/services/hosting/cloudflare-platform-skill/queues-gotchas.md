# Gotchas

See [queues.md](./queues.md), [queues-patterns.md](./queues-patterns.md).

## Delivery Semantics

Queues are at-least-once. Consumers must tolerate duplicates and should ack only after durable success.

```typescript
// ✅ GOOD: Track processed messages
const processed = await env.PROCESSED_KV.get(msg.id);
if (processed) { msg.ack(); continue; }
await processMessage(msg.body);
await env.PROCESSED_KV.put(msg.id, '1', { expirationTtl: 86400 });
msg.ack();
```

## Content Type Visibility

- `json` is dashboard-visible and works with pull consumers.
- `v8` is not decodable in pull consumers or the dashboard.
- For pull consumers, send `json`.

```typescript
// ✅ For pull consumers
await env.MY_QUEUE.send(data, { contentType: 'json' });

// ❌ Avoid v8 with pull
await env.MY_QUEUE.send(new Date(), { contentType: 'v8' }); // Can't decode
```

## Retries and CPU Budget

If a handler exits without `ack()` or `retry()`, Cloudflare retries with the queue's configured policy. Default consumer CPU budget is 30s; raise it for heavier work.

```typescript
// If you DON'T call ack() or retry(), message retries automatically
async queue(batch: MessageBatch): Promise<void> {
  for (const msg of batch.messages) {
    try {
      await processMessage(msg.body);
      msg.ack(); // Explicit success
    } catch (error) {
      // Don't call retry() - auto-retries with configured delay
      // OR call retry() with custom delay
      msg.retry({ delaySeconds: 600 });
    }
  }
}
```

```jsonc
{ "limits": { "cpu_ms": 300000 } } // 5 minutes
```

## Cost and Throughput

Each message normally incurs write + read + delete = 3 ops. Retries add reads. Monthly queue cost beyond the free tier is `((messages × 3) - 1M) / 1M × $0.40`.

```typescript
// Keep messages <64 KB (charged per 64 KB chunk)
// Batch aggressively to reduce frequency
{ "max_batch_size": 100, "max_batch_timeout": 30 }
```

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
# Check queue paused
wrangler queues list

# Verify consumer configured
wrangler queues consumer worker remove my-queue my-worker
wrangler queues consumer add my-queue my-worker

# Check logs for errors
wrangler tail my-worker
```

### High DLQ rate

- Review consumer error logs.
- Check external dependency availability.
- Verify message format matches expectations.
- Increase retry delay: `"retry_delay": 300`.

## Best Practices

- ✅ Design for idempotency.
- ✅ Use `json` for visibility and pull compatibility.
- ✅ Log failures with enough context to replay or diagnose.
- ✅ Configure a DLQ for permanent failures.
- ✅ Use `waitUntil()` for non-blocking sends.
- ✅ Batch sends when possible.
- ❌ Don't use `v8` with pull consumers.
- ❌ Don't rely on message ordering.
