<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudflare Durable Objects

Globally-unique compute + storage: single-threaded, strongly-consistent, co-located with state. Spawns near first request.

## When to Use DOs

Stateful coordination — serialized access to shared state:
- **Coordination**: shared state across clients (chat rooms, multiplayer games)
- **Strong consistency**: serialized operations (booking systems, inventory)
- **Per-entity storage**: isolated database per user/tenant/resource (multi-tenant SaaS)
- **Persistent connections**: long-lived WebSockets surviving across requests
- **Per-entity scheduled work**: timers per entity (subscription renewals, game timeouts)

## When NOT to Use DOs

| Scenario | Use Instead |
|----------|-------------|
| Stateless request handling | Workers |
| Maximum global distribution | Workers |
| High fan-out (independent requests) | Workers |
| Global singleton handling all traffic | Shard across multiple DOs |
| High-frequency pub/sub | Queues |
| Long-running continuous processes | Workers + Alarms |
| Chatty microservice (every request) | Reconsider architecture |
| Eventual consistency OK, read-heavy | KV |
| Relational queries across entities | D1 |

## Design Heuristics

Model each DO around the **atom of coordination** — the unit needing serialized access (user, room, document, session).

| Metric | Feels Right | Question It | Reconsider |
|----------------|-------------|-------------|------------|
| Requests/sec (sustained) | < 100 | 100-500 | > 500 |
| Storage keys | < 100 | 100-1000 | > 1000 |
| Total state size | < 10MB | 10MB-100MB | > 1GB |
| Alarm frequency | Minutes-hours | Every 30s | Every few seconds |
| WebSocket duration | Short bursts | Hours (hibernating) | Days always-on |
| Fan-out from this DO | Never/rarely | To < 10 DOs | To 100+ DOs |

## Core Concepts

| Concept | Detail |
|---------|--------|
| **Class** | Extend `DurableObject`. Constructor receives `DurableObjectState` (storage, WebSockets, alarms) and `Env` (bindings). |
| **Access** | Workers get stubs via bindings → RPC methods (recommended) or fetch handler (legacy). |
| **ID generation** | `idFromName()` deterministic; `newUniqueId()` random/sharding; `idFromString()` from existing; jurisdiction for data locality. |
| **Storage** | SQLite default (10GB/DO, transactions); Sync KV API (simple key-value); Async KV API (legacy/advanced). |
| **Special features** | Alarms (per-DO scheduled execution); WebSocket Hibernation (zero-cost idle); PITR (30-day window). |

## Quick Start

```typescript
import { DurableObject } from "cloudflare:workers";

export class Counter extends DurableObject<Env> {
  async increment(): Promise<number> {
    const result = this.ctx.storage.sql.exec(
      `INSERT INTO counters (id, value) VALUES (1, 1)
       ON CONFLICT(id) DO UPDATE SET value = value + 1
       RETURNING value`
    ).one();
    return result.value;
  }
}

// Worker access
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const id = env.COUNTER.idFromName("global");
    const stub = env.COUNTER.get(id);
    const count = await stub.increment();
    return new Response(`Count: ${count}`);
  }
};
```

## Essential Commands

```bash
npx wrangler dev              # Local dev with DOs
npx wrangler dev --remote     # Test against prod DOs
npx wrangler deploy           # Deploy + auto-apply migrations
```

## Resources

- [Docs](https://developers.cloudflare.com/durable-objects/)
- [API Reference](https://developers.cloudflare.com/durable-objects/api/)
- [Examples](https://developers.cloudflare.com/durable-objects/examples/)

## See Also

- [Patterns](./durable-objects-patterns.md) — Rate limiting, locks, real-time collab, sessions
- [Gotchas](./durable-objects-gotchas.md) — Limits, common issues, troubleshooting
- [Workers](./workers.md) — Core Workers runtime
- [DO Storage](./do-storage.md) — Deep dive on storage APIs
