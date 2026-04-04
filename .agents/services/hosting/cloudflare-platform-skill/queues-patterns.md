<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Queues Patterns

## Async Task Processing

Producer enqueues work, consumer processes in background.

```typescript
// Producer
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const { userId, reportType } = await request.json();
    await env.REPORT_QUEUE.send({ userId, reportType, requestedAt: Date.now() });
    return Response.json({ message: 'Report queued', status: 'pending' });
  }
};

// Consumer
export default {
  async queue(batch: MessageBatch, env: Env): Promise<void> {
    for (const msg of batch.messages) {
      const { userId, reportType } = msg.body;
      await env.REPORTS_BUCKET.put(`${userId}/${reportType}.pdf`, await generateReport(userId, reportType, env));
      msg.ack();
    }
  }
};
```

## Buffering API Calls

Collect entries via `waitUntil`, batch-write to external API.

```typescript
// Producer — non-blocking
ctx.waitUntil(env.LOGS_QUEUE.send({ method: request.method, url: request.url, timestamp: Date.now() }));

// Consumer — batch write
async queue(batch: MessageBatch, env: Env): Promise<void> {
  await fetch(env.LOG_ENDPOINT, { method: 'POST', body: JSON.stringify({ logs: batch.messages.map(m => m.body) }) });
  batch.ackAll();
}
```

## Fan-out

Publish one event to multiple queues for parallel processing.

```typescript
async fetch(request: Request, env: Env): Promise<Response> {
  const event = await request.json();
  await Promise.all([
    env.ANALYTICS_QUEUE.send(event),
    env.NOTIFICATIONS_QUEUE.send(event),
    env.AUDIT_LOG_QUEUE.send(event)
  ]);
  return Response.json({ status: 'processed' });
}
```

## Rate Limiting Upstream

Retry on 429 with `Retry-After` header delay.

```typescript
async queue(batch: MessageBatch, env: Env): Promise<void> {
  for (const msg of batch.messages) {
    try {
      await callRateLimitedAPI(msg.body);
      msg.ack();
    } catch (error) {
      if (error.status === 429) msg.retry({ delaySeconds: parseInt(error.headers.get('Retry-After') || '60') });
      else throw error;
    }
  }
}
```

## Event-Driven Workflows

React to R2 (or other) events routed through a queue.

```typescript
export default {
  async queue(batch: MessageBatch, env: Env): Promise<void> {
    for (const msg of batch.messages) {
      const event = msg.body;
      if (event.action === 'PutObject') await processNewFile(event.object.key, env);
      else if (event.action === 'DeleteObject') await cleanupReferences(event.object.key, env);
      msg.ack();
    }
  }
};
```

## Dead Letter Queue

After `max_retries`, messages route to DLQ automatically. Persist for investigation.

```typescript
// Main queue consumer
export default {
  async queue(batch: MessageBatch, env: Env): Promise<void> {
    for (const msg of batch.messages) {
      try { await riskyOperation(msg.body); msg.ack(); }
      catch (error) { console.error(`Failed after ${msg.attempts} attempts:`, error); }
    }
  }
};

// DLQ consumer — persist failed messages
export default {
  async queue(batch: MessageBatch, env: Env): Promise<void> {
    for (const msg of batch.messages) {
      await env.FAILED_KV.put(msg.id, JSON.stringify(msg.body));
      msg.ack();
    }
  }
};
```

## Configuration Patterns

**Priority queues** — tune batch settings per priority level:
- High priority: `max_batch_size: 5, max_batch_timeout: 1`
- Low priority: `max_batch_size: 100, max_batch_timeout: 30`

**Delayed jobs** — defer processing up to 12 hours:

```typescript
await env.EMAIL_QUEUE.send({ to, template, userId }, { delaySeconds: 3600 });
```

**Idempotency** — at-least-once delivery means duplicates are possible. See [queues-gotchas.md](./queues-gotchas.md#idempotency-required) for the dedup pattern.
