# Multi-Tenant Patterns

## Billing by Plan

```typescript
interface Env {
  DISPATCHER: DispatchNamespace;
  CUSTOMERS_KV: KVNamespace;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const userWorkerName = new URL(request.url).hostname.split(".")[0];
    const customerPlan = await env.CUSTOMERS_KV.get(userWorkerName);
    
    const plans = {
      enterprise: { cpuMs: 50, subRequests: 50 },
      pro: { cpuMs: 20, subRequests: 20 },
      free: { cpuMs: 10, subRequests: 5 },
    };
    const limits = plans[customerPlan as keyof typeof plans] || plans.free;
    
    const userWorker = env.DISPATCHER.get(userWorkerName, {}, { limits });
    return await userWorker.fetch(request);
  },
};
```

## Resource Isolation

Create unique resources per customer (KV namespace, D1 database, R2 bucket):

```typescript
const bindings = [{
  type: "kv_namespace",
  name: "USER_KV",
  namespace_id: `customer-${customerId}-kv`
}];
```

## Hostname Routing

### Wildcard Route (Recommended)

Configure `*/*` route on SaaS domain → dispatch Worker. Supports subdomains + custom vanity domains, no route limits, works regardless of DNS proxy settings.

**Setup:** Cloudflare for SaaS custom hostnames → fallback origin (dummy `A 192.0.2.0` if Worker is origin) → DNS CNAME to SaaS domain → `*/*` route → dispatch Worker with routing logic:

```typescript
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const hostname = new URL(request.url).hostname;
    const hostnameData = await env.ROUTING_KV.get(`hostname:${hostname}`, { type: "json" });
    
    if (!hostnameData?.workerName) {
      return new Response("Hostname not configured", { status: 404 });
    }
    
    const userWorker = env.DISPATCHER.get(hostnameData.workerName);
    return await userWorker.fetch(request);
  },
};
```

### Subdomain-Only

Wildcard DNS `*.saas.com` → origin, route `*.saas.com/*` → dispatch Worker, extract subdomain for routing.

**Orange-to-Orange:** When customers use Cloudflare and CNAME to your domain, use `*/*` wildcard for consistent behavior.

## Observability

**Logpush:** Enable on dispatch Worker → captures all user Worker logs. Filter by `Outcome` or `Script Name`.

**Tail Workers:** Real-time logs with custom formatting — receives HTTP status, `console.log()`, exceptions, diagnostics.

**Analytics Engine** — track violations:

```typescript
env.ANALYTICS.writeDataPoint({
  indexes: [customerName],
  blobs: ["cpu_limit_exceeded"],
});
```

**GraphQL** — aggregate metrics:

```graphql
query {
  viewer {
    accounts(filter: {accountTag: $accountId}) {
      workersInvocationsAdaptive(filter: {dispatchNamespaceName: "production"}) {
        sum { requests errors cpuTime }
      }
    }
  }
}
```

## Use Case Implementations

### AI Code Execution

```typescript
async function deployGeneratedCode(name: string, code: string) {
  const file = new File([code], `${name}.mjs`, { type: "application/javascript+module" });
  await client.workersForPlatforms.dispatch.namespaces.scripts.update("production", name, {
    account_id: accountId,
    metadata: { main_module: `${name}.mjs`, tags: [name, "ai-generated"] },
    files: [file],
  });
}

// Short limits for untrusted code
const userWorker = env.DISPATCHER.get(sessionId, {}, { limits: { cpuMs: 5, subRequests: 3 } });
```

### Edge Functions Platform

```typescript
// Route: /customer-id/function-name
const [customerId, functionName] = new URL(request.url).pathname.split("/").filter(Boolean);
const workerName = `${customerId}-${functionName}`;
const userWorker = env.DISPATCHER.get(workerName);
```

See [workers-for-platforms.md](./workers-for-platforms.md), [gotchas.md](./workers-for-platforms-gotchas.md)
