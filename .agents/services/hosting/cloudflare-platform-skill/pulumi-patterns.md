# Architecture Patterns

## Component Resources

Encapsulate related resources (Worker + KV + domain) as a reusable unit with automatic parent-child relationships.

```typescript
class WorkerApp extends pulumi.ComponentResource {
    constructor(name: string, args: WorkerAppArgs, opts?) {
        super("custom:cloudflare:WorkerApp", name, {}, opts);
        const defaultOpts = {parent: this};

        this.kv = new cloudflare.WorkersKvNamespace(`${name}-kv`, {accountId: args.accountId, title: `${name}-kv`}, defaultOpts);
        this.worker = new cloudflare.WorkerScript(`${name}-worker`, {
            accountId: args.accountId, name: `${name}-worker`, content: args.workerCode,
            module: true, kvNamespaceBindings: [{name: "KV", namespaceId: this.kv.id}],
        }, defaultOpts);
        this.domain = new cloudflare.WorkersDomain(`${name}-domain`, {
            accountId: args.accountId, hostname: args.domain, service: this.worker.name,
        }, defaultOpts);
    }
}
```

## Full-Stack Worker App

Provision a Worker with KV, D1, and R2 bindings. Set `compatibilityDate` and `compatibilityFlags` to lock runtime behaviour.

```typescript
const kv = new cloudflare.WorkersKvNamespace("cache", {accountId, title: "api-cache"});
const db = new cloudflare.D1Database("db", {accountId, name: "app-database"});
const bucket = new cloudflare.R2Bucket("assets", {accountId, name: "app-assets"});

const apiWorker = new cloudflare.WorkerScript("api", {
    accountId, name: "api-worker", content: fs.readFileSync("./dist/api.js", "utf8"),
    module: true, compatibilityDate: "2024-01-01", compatibilityFlags: ["nodejs_compat"],
    kvNamespaceBindings: [{name: "CACHE", namespaceId: kv.id}],
    d1DatabaseBindings: [{name: "DB", databaseId: db.id}],
    r2BucketBindings: [{name: "ASSETS", bucketName: bucket.name}],
});
```

## Multi-Environment Setup

Use `pulumi.getStack()` to namespace resources per environment. Inject the stack name as a binding for runtime access.

```typescript
const stack = pulumi.getStack();
const worker = new cloudflare.WorkerScript(`worker-${stack}`, {
    accountId, name: `my-worker-${stack}`, content: code,
    plainTextBindings: [{name: "ENVIRONMENT", text: stack}],
});
```

## Queue-Based Processing

Producer/consumer pattern — one Worker enqueues, another processes asynchronously. For fan-out, use `.map()` to create multiple producers or consumers from a single queue.

```typescript
const queue = new cloudflare.Queue("processing-queue", {accountId, name: "image-processing"});

const apiWorker = new cloudflare.WorkerScript("api", {
    accountId, name: "api-worker", content: apiCode,
    queueBindings: [{name: "PROCESSING_QUEUE", queue: queue.id}],
});

const processorWorker = new cloudflare.WorkerScript("processor", {
    accountId, name: "processor-worker", content: processorCode,
    queueConsumers: [{queue: queue.name, maxBatchSize: 10, maxRetries: 3, maxWaitTimeMs: 5000}],
    r2BucketBindings: [{name: "OUTPUT_BUCKET", bucketName: outputBucket.name}],
});

// Fan-out: multiple consumers from one event bus
const eventQueue = new cloudflare.Queue("events", {accountId, name: "event-bus"});
const consumers = ["email", "analytics"].map(name =>
    new cloudflare.WorkerScript(`${name}-consumer`, {
        accountId, name: `${name}-consumer`, content: consumerCode,
        queueConsumers: [{queue: eventQueue.name, maxBatchSize: 10}],
    })
);
```

## Microservices with Service Bindings

Zero-latency RPC between Workers via service bindings — no network hop.

```typescript
const authWorker = new cloudflare.WorkerScript("auth", {accountId, name: "auth-service", content: authCode});
const apiWorker = new cloudflare.WorkerScript("api", {
    accountId, name: "api-service", content: apiCode,
    serviceBindings: [{name: "AUTH", service: authWorker.name}],
});
// In worker: await env.AUTH.fetch("/verify", {...});
```

## CDN with Dynamic Content

R2 for static assets + Worker for dynamic routing via `WorkerRoute`.

```typescript
const staticBucket = new cloudflare.R2Bucket("static", {accountId, name: "static-assets"});
const appWorker = new cloudflare.WorkerScript("app", {
    accountId, name: "app-worker", content: appCode,
    r2BucketBindings: [{name: "STATIC", bucketName: staticBucket.name}],
});
const route = new cloudflare.WorkerRoute("route", {zoneId, pattern: `${domain}/*`, scriptName: appWorker.name});
```

## Dynamic Worker Content

Build Worker code as a Pulumi dependency so `pulumi up` triggers the build step first.

```typescript
import * as command from "@pulumi/command";
const build = new command.local.Command("build-worker", {create: "npm run build", dir: "./worker"});
const workerContent = build.stdout.apply(() => fs.readFileSync("./worker/dist/index.js", "utf8"));
const worker = new cloudflare.WorkerScript("worker", {accountId, name: "my-worker", content: workerContent}, {dependsOn: [build]});
```

## Conditional Resources

Provision resources only in specific environments. Pass empty binding arrays when the resource is absent.

```typescript
const isProd = pulumi.getStack() === "prod";
const analytics = isProd ? new cloudflare.WorkersKvNamespace("analytics", {accountId, title: "analytics"}) : undefined;
const worker = new cloudflare.WorkerScript("worker", {
    accountId, name: "worker", content: code,
    kvNamespaceBindings: analytics ? [{name: "ANALYTICS", namespaceId: analytics.id}] : [],
});
```

---
See: [pulumi.md](./pulumi.md), [pulumi-gotchas.md](./pulumi-gotchas.md)
