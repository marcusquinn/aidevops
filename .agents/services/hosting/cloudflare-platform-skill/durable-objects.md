# Cloudflare Durable Objects

Compute + storage in globally-unique, strongly-consistent packages:
- **Globally unique instances**: Unique ID per DO for multi-client coordination
- **Co-located storage**: Strongly-consistent storage with compute
- **Automatic placement**: Spawns near first request
- **Stateful serverless**: In-memory state + persistent storage
- **Single-threaded**: Serial request processing (no race conditions)

## When to Use DOs

**Stateful coordination**, not stateless request handling:
- **Coordination**: Shared state across clients (chat rooms, multiplayer games)
- **Strong consistency**: Serialized operations (booking systems, inventory)
- **Per-entity storage**: Isolated database per user/tenant/resource (multi-tenant SaaS)
- **Persistent connections**: Long-lived WebSockets surviving across requests
- **Per-entity scheduled work**: Per-entity timers (subscription renewals, game timeouts)

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

| Characteristic | Feels Right | Question It | Reconsider |
|----------------|-------------|-------------|------------|
| Requests/sec (sustained) | < 100 | 100-500 | > 500 |
| Storage keys | < 100 | 100-1000 | > 1000 |
| Total state size | < 10MB | 10MB-100MB | > 1GB |
| Alarm frequency | Minutes-hours | Every 30s | Every few seconds |
| WebSocket duration | Short bursts | Hours (hibernating) | Days always-on |
| Fan-out from this DO | Never/rarely | To < 10 DOs | To 100+ DOs |

## Core Concepts

### Class Structure

Extend `DurableObject` base class. Constructor receives `DurableObjectState` (storage, WebSockets, alarms) and `Env` (bindings).

### Accessing from Workers

Workers get stubs via bindings, then call RPC methods (recommended) or use fetch handler (legacy).

### ID Generation

- `idFromName()`: Deterministic, named coordination
- `newUniqueId()`: Random IDs for sharding
- `idFromString()`: Derive from existing IDs
- Jurisdiction option: Data locality

### Storage Options

- **SQLite** (recommended): Structured data, transactions, 10GB/DO
- **Synchronous KV API**: Simple key-value on SQLite objects
- **Asynchronous KV API**: Legacy/advanced use cases

### Special Features

- **Alarms**: Schedule future execution per-DO
- **WebSocket Hibernation**: Zero-cost idle connections
- **Point-in-Time Recovery**: Restore to any point in 30 days

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

**Docs**: https://developers.cloudflare.com/durable-objects/  
**API Reference**: https://developers.cloudflare.com/durable-objects/api/  
**Examples**: https://developers.cloudflare.com/durable-objects/examples/

## In This Reference

- [Patterns](./durable-objects-patterns.md) - Rate limiting, locks, real-time collab, sessions
- [Gotchas](./durable-objects-gotchas.md) - Limits, common issues, troubleshooting

## See Also

- [Workers](./workers.md) - Core Workers runtime
- [DO Storage](./do-storage.md) - Deep dive on storage APIs
