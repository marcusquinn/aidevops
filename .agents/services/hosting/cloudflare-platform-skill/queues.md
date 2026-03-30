# Cloudflare Queues

Flexible message queuing for async task processing. At-least-once delivery, push-based (Worker) and pull-based (HTTP) consumers, configurable batching/retries, Dead Letter Queues (DLQ), delays up to 12 hours.

**Use cases:** Async processing, API buffering, rate limiting, event workflows, deferred jobs

## Quick Start

```bash
wrangler queues create my-queue
wrangler queues consumer add my-queue my-worker
```

```typescript
// Producer
await env.MY_QUEUE.send({ userId: 123, action: 'notify' });

// Consumer
export default {
  async queue(batch: MessageBatch, env: Env): Promise<void> {
    for (const msg of batch.messages) {
      await process(msg.body);
      msg.ack();
    }
  }
};
```

## Core Operations

| Operation | Purpose | Limit |
|-----------|---------|-------|
| `send(body, options?)` | Publish message | 128 KB |
| `sendBatch(messages)` | Bulk publish | 100 msgs/256 KB |
| `message.ack()` | Acknowledge success | - |
| `message.retry(options?)` | Retry with delay | - |
| `batch.ackAll()` | Ack entire batch | - |

## See Also

- [queues-patterns.md](./queues-patterns.md) — async tasks, buffering, rate limiting, fan-out, event workflows, DLQ
- [queues-gotchas.md](./queues-gotchas.md) — idempotency, retry limits, content types, cost optimization, limits
- [workers](../workers/) — Worker runtime for producers/consumers
- [r2](../r2/) — process R2 event notifications via queues
- [d1](../d1/) — batch write to D1 from queue consumers
