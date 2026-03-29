# Testing Patterns

## Basic Test Setup (node:test)

```js
import assert from "node:assert";
import test, { after, before } from "node:test";
import { Miniflare } from "miniflare";

let mf;

before(async () => {
  mf = new Miniflare({
    modules: true,
    scriptPath: "src/index.js",
    kvNamespaces: ["TEST_KV"],
    bindings: { API_KEY: "test-key" },
  });
  await mf.ready;
});

test("fetch returns hello", async () => {
  const res = await mf.dispatchFetch("http://localhost/");
  assert.strictEqual(await res.text(), "Hello World");
});

test("kv operations", async () => {
  const kv = await mf.getKVNamespace("TEST_KV");
  await kv.put("key", "value");
  const res = await mf.dispatchFetch("http://localhost/kv");
  assert.strictEqual(await res.text(), "value");
});

after(async () => {
  await mf.dispose();
});
```

## Testing Durable Objects

```js
test("durable object state", async () => {
  const ns = await mf.getDurableObjectNamespace("COUNTER");
  const id = ns.idFromName("test-counter");
  const stub = ns.get(id);

  const res1 = await stub.fetch("http://localhost/increment");
  assert.strictEqual(await res1.text(), "1");

  const res2 = await stub.fetch("http://localhost/increment");
  assert.strictEqual(await res2.text(), "2");

  const storage = await mf.getDurableObjectStorage(id);
  const count = await storage.get("count");
  assert.strictEqual(count, 2);
});
```

## Testing Queue Handlers

```js
test("queue message processing", async () => {
  const worker = await mf.getWorker();

  const result = await worker.queue("my-queue", [
    { id: "msg1", timestamp: new Date(), body: { userId: 123 }, attempts: 1 },
  ]);

  assert.strictEqual(result.outcome, "ok");

  const kv = await mf.getKVNamespace("QUEUE_LOG");
  const log = await kv.get("msg1");
  assert.ok(log);
});
```

## Testing Scheduled Events

```js
test("scheduled cron handler", async () => {
  const worker = await mf.getWorker();

  const result = await worker.scheduled({
    scheduledTime: new Date("2024-01-01T00:00:00Z"),
    cron: "0 0 * * *",
  });

  assert.strictEqual(result.outcome, "ok");
});
```

## Isolated Test Data

```js
import test, { beforeEach, afterEach } from "node:test";
import { Miniflare } from "miniflare";

let mf;

beforeEach(async () => {
  mf = new Miniflare({
    scriptPath: "worker.js",
    kvNamespaces: ["USERS"],
    // In-memory: no persist option = fresh state each run
  });
  await mf.ready;
});

afterEach(async () => {
  await mf.dispose();
});

test("create user", async () => {
  const res = await mf.dispatchFetch("http://localhost/users", {
    method: "POST",
    body: JSON.stringify({ name: "Alice" }),
  });
  assert.strictEqual(res.status, 201);
});
```

## Mock External Services

```js
new Miniflare({
  workers: [
    {
      name: "main",
      serviceBindings: { EXTERNAL_API: "mock-api" },
      script: `/* main worker */`,
    },
    {
      name: "mock-api",
      script: `
        addEventListener("fetch", (event) => {
          event.respondWith(Response.json({ mocked: true }));
        })
      `,
    },
  ],
});
```

## Shared Storage Between Workers

```js
new Miniflare({
  kvPersist: "./data",
  workers: [
    { name: "writer", kvNamespaces: { DATA: "shared" }, script: `...` },
    { name: "reader", kvNamespaces: { DATA: "shared" }, script: `...` },
  ],
});
```

## Test Utils Pattern

```js
// test-utils.js
export async function createTestWorker(overrides = {}) {
  const mf = new Miniflare({
    scriptPath: "dist/worker.js",
    kvNamespaces: ["TEST_KV"],
    bindings: { ENVIRONMENT: "test", ...overrides.bindings },
    ...overrides,
  });
  await mf.ready;
  return mf;
}

// test.js
test("my test", async () => {
  const mf = await createTestWorker({ bindings: { CUSTOM: "value" } });
  try {
    const res = await mf.dispatchFetch("http://localhost/");
    assert.ok(res.ok);
  } finally {
    await mf.dispose();
  }
});
```

## CI Integration

Use in-memory storage (omit persist options) for CI speed. Use `dispatchFetch` instead of HTTP server to avoid port conflicts.

See [gotchas.md](./gotchas.md) for troubleshooting common issues.
