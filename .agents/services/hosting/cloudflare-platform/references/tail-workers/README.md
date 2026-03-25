# Cloudflare Tail Workers

## Purpose

Expert guidance on Cloudflare Tail Workers—specialized Workers that consume execution events from producer Workers for logging, debugging, analytics, and observability.

## When to Use

- Implementing observability/logging for Cloudflare Workers
- Processing Worker execution events, logs, exceptions
- Building custom analytics or error tracking
- Configuring real-time event streaming
- User mentions tail handlers, tail consumers, or producer Workers

## Core Concepts

Tail Workers automatically process events from producer Workers after they finish executing. They receive:
- HTTP request/response info
- Console logs (`console.log/error/warn/debug`)
- Uncaught exceptions
- Execution outcomes (`ok`, `exception`, `exceededCpu`, etc.)
- Diagnostic channel events

**Key characteristics:**
- Invoked AFTER producer finishes executing
- Capture entire request lifecycle including Service Bindings and Dynamic Dispatch sub-requests
- Billed by CPU time, not request count
- Available on Workers Paid and Enterprise tiers

**Alternative: OpenTelemetry Export** — For batch exports to observability tools (Sentry, Grafana, Honeycomb), consider OTEL export instead. OTEL sends logs/traces in batches (more efficient). Tail Workers = advanced mode for custom processing.

## Basic Structure

```typescript
export default {
  async tail(events: TailItem[], env: Env, ctx: ExecutionContext): Promise<void> {
    // Process events from producer Worker
    // CRITICAL: Use ctx.waitUntil() for async work — tail handlers don't return values
    ctx.waitUntil(processEvents(events, env));
  }
} satisfies ExportedHandler<Env>;
```

## Event Structure (`TailItem`)

```typescript
interface TailItem {
  scriptName: string;
  eventTimestamp: number;
  outcome: 'ok' | 'exception' | 'exceededCpu' | 'exceededMemory'
         | 'canceled' | 'scriptNotFound' | 'responseStreamDisconnected' | 'unknown';
  event: {
    request?: {
      url: string;               // Redacted by default
      method: string;
      headers: Record<string, string>;  // Sensitive headers redacted
      cf: IncomingRequestCfProperties;
      getUnredacted(): TailRequest;     // Bypass redaction (use carefully)
    };
    response?: { status: number };
  };
  logs: Array<{ timestamp: number; level: 'debug'|'info'|'log'|'warn'|'error'; message: any[] }>;
  exceptions: Array<{ timestamp: number; name: string; message: string }>;
  diagnosticsChannelEvents: Array<{ channel: string; message: any; timestamp: number }>;
}
```

## Configuration

**Producer Worker `wrangler.toml`:**

```toml
name = "my-producer-worker"
tail_consumers = [{service = "my-tail-worker"}]
```

**Producer Worker `wrangler.jsonc`:**

```json
{
  "name": "my-producer-worker",
  "tail_consumers": [{ "service": "my-tail-worker" }]
}
```

The Tail Worker itself needs no special config — just a `tail()` handler.

## Common Use Cases

### Send Logs to HTTP Endpoint

```typescript
ctx.waitUntil(
  fetch(env.LOG_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(events.map(e => ({
      script: e.scriptName, timestamp: e.eventTimestamp, outcome: e.outcome,
      url: e.event?.request?.url, status: e.event?.response?.status,
      logs: e.logs, exceptions: e.exceptions,
    }))),
  })
);
```

### Error Tracking

```typescript
for (const event of events.filter(e => e.outcome === 'exception' || e.exceptions.length > 0)) {
  ctx.waitUntil(
    fetch("https://error-tracker.example.com/errors", {
      method: "POST",
      headers: { "Authorization": `Bearer ${env.ERROR_TRACKER_TOKEN}`, "Content-Type": "application/json" },
      body: JSON.stringify({ script: event.scriptName, exceptions: event.exceptions, logs: event.logs }),
    })
  );
}
```

### Store Logs in KV

```typescript
ctx.waitUntil(Promise.all(
  events.map(e => env.LOGS_KV.put(
    `log:${e.scriptName}:${e.eventTimestamp}`,
    JSON.stringify({ outcome: e.outcome, logs: e.logs, exceptions: e.exceptions }),
    { expirationTtl: 86400 }  // 24 hours
  ))
));
```

### Analytics Engine

```typescript
ctx.waitUntil(Promise.all(
  events.map(e => env.ANALYTICS.writeDataPoint({
    blobs: [e.scriptName, e.outcome, e.event?.request?.method ?? 'unknown'],
    doubles: [1, e.event?.response?.status ?? 0],
    indexes: [e.event?.request?.cf?.colo ?? 'unknown'],
  }))
));
```

### Filter Specific Routes

```typescript
const apiEvents = events.filter(e => e.event?.request?.url?.includes('/api/'));
if (apiEvents.length === 0) return;
ctx.waitUntil(fetch(env.API_LOGS_ENDPOINT, { method: "POST", body: JSON.stringify(apiEvents) }));
```

### Multi-Destination Logging

```typescript
const errors = events.filter(e => e.outcome === 'exception');
const success = events.filter(e => e.outcome === 'ok');
const tasks = [];
if (errors.length > 0) tasks.push(fetch(env.ERROR_ENDPOINT, { method: "POST", body: JSON.stringify(errors) }));
if (success.length > 0) tasks.push(fetch(env.SUCCESS_ENDPOINT, { method: "POST", body: JSON.stringify(success) }));
ctx.waitUntil(Promise.all(tasks));
```

## Security & Privacy

### Automatic Redaction

**Header redaction**: Headers containing `auth`, `key`, `secret`, `token`, `jwt` (case-insensitive), plus `cookie`/`set-cookie` → shown as `"REDACTED"`.

**URL redaction**: Hex IDs (32+ hex digits) and base-64 IDs (21+ chars) → `"REDACTED"`.

### Bypassing Redaction

```typescript
// Use with extreme caution
const unredacted = event.event?.request?.getUnredacted();
```

Best practices: only call when absolutely necessary, never log unredacted sensitive data, filter before external transmission, use env vars for API keys.

## Wrangler CLI

```bash
wrangler deploy                          # Deploy Tail Worker
wrangler tail <producer-worker-name>     # Stream logs to terminal (NOT Tail Workers — different feature)
```

To remove a tail consumer, set `tail_consumers = []` in `wrangler.toml` and redeploy.

## Testing & Development

Tail Workers cannot be fully tested locally with `wrangler dev`. Deploy to staging:

1. Deploy producer Worker to staging
2. Deploy Tail Worker to staging
3. Configure `tail_consumers` in producer
4. Trigger producer Worker requests
5. Verify Tail Worker receives events (check destination logs/storage)

```typescript
// Debugging pattern
export default {
  async tail(events, env, ctx) {
    console.log('Received events:', events.length);
    ctx.waitUntil(
      (async () => {
        try {
          await processEvents(events, env);
        } catch (error) {
          console.error('Tail Worker error:', error);
        }
      })()
    );
  }
};
```

## Advanced Patterns

### Batching with Durable Objects

```typescript
const batch = await env.BATCH_DO.get(env.BATCH_DO.idFromName("batch"));
ctx.waitUntil(batch.addEvents(events));
```

### Sampling

```typescript
const sampledEvents = events.filter(() => Math.random() < 0.1);  // 10%
if (sampledEvents.length > 0) ctx.waitUntil(sendToEndpoint(sampledEvents, env));
```

### Workers for Platforms

For dynamic dispatch Workers, `events` contains TWO elements (dispatch Worker event + user Worker event). Distinguish by `event.scriptName`.

## Common Pitfalls

1. **Not using `ctx.waitUntil()`** — async work may not complete before the handler returns
2. **Missing `tail()` handler** — producer deployment fails if `tail_consumers` references a Worker without it
3. **Outcome vs HTTP status** — `outcome` is script execution status, NOT HTTP status. A Worker can return 500 but have `outcome='ok'`
4. **Excessive logging** — Tail Workers invoke on EVERY producer invocation; be mindful of volume and costs
5. **Blocking operations** — don't `await` in tail handler unless necessary; use `ctx.waitUntil()` for fire-and-forget

## Integration Examples

### Sentry

```typescript
for (const event of events.filter(e => e.outcome === 'exception' || e.exceptions.length > 0)) {
  ctx.waitUntil(
    fetch(`https://sentry.io/api/${env.SENTRY_PROJECT}/store/`, {
      method: "POST",
      headers: { "X-Sentry-Auth": `Sentry sentry_key=${env.SENTRY_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        message: event.exceptions[0]?.message, level: "error",
        tags: { worker: event.scriptName }, extra: { event },
      }),
    })
  );
}
```

### Datadog

```typescript
ctx.waitUntil(
  fetch("https://http-intake.logs.datadoghq.com/v1/input", {
    method: "POST",
    headers: { "DD-API-KEY": env.DATADOG_API_KEY, "Content-Type": "application/json" },
    body: JSON.stringify(events.flatMap(e =>
      e.logs.map(log => ({
        ddsource: "cloudflare-worker",
        ddtags: `worker:${e.scriptName},outcome:${e.outcome}`,
        hostname: e.event?.request?.cf?.colo,
        message: log.message.join(" "),
        status: log.level,
        timestamp: log.timestamp,
      }))
    )),
  })
);
```

## Decision Tree

```
Need observability for Workers?
├─ Batch export to known tools (Sentry/Grafana/Honeycomb)?
│  └─ Use OpenTelemetry export (not Tail Workers)
├─ Custom real-time processing needed?
│  ├─ Aggregated metrics? → Tail Worker + Analytics Engine
│  ├─ Error tracking? → Tail Worker + external service
│  ├─ Custom logging? → Tail Worker + KV/HTTP endpoint
│  └─ Complex event processing? → Tail Worker + Durable Objects
└─ Quick debugging? → `wrangler tail` (different from Tail Workers)
```

## Related Resources

- [Tail Workers Docs](https://developers.cloudflare.com/workers/observability/logs/tail-workers/)
- [Tail Handler API](https://developers.cloudflare.com/workers/runtime-apis/handlers/tail/)
- [Analytics Engine](https://developers.cloudflare.com/analytics/analytics-engine/)
- [OpenTelemetry Export](https://developers.cloudflare.com/workers/observability/exporting-opentelemetry-data/)
