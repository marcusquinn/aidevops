# Hyperdrive

Connect Workers to PostgreSQL or MySQL with edge connection setup, pooled origin connections, and optional caching for non-mutating queries. Removes ~7 TCP/TLS/auth round-trips per connection.

Compatible with CockroachDB, Timescale, PlanetScale, Neon, and Supabase.

## Best Fit

- **Use when**: users are globally distributed, the database is single-region, reads dominate, or connection setup cost is hurting latency.
- **Avoid when**: writes dominate, freshness must stay under 1 second, or the Worker runs in the same region as the database.

## Core Capabilities

- **Connection pooling**: reuses origin connections instead of reconnecting on every request.
- **Edge setup**: negotiates connections at the edge while pooling near the database.
- **Query caching**: caches non-mutating queries for 60 seconds by default.

## Architecture

```text
Worker → Edge (setup) → Pool (near DB) → Origin
         ↓ cached reads
         Cache
```

## Quick Start

```bash
npx wrangler hyperdrive create my-db \
  --connection-string="postgres://user:pass@host:5432/db"
```

```jsonc
// wrangler.jsonc
{
  "compatibility_flags": ["nodejs_compat"],
  "hyperdrive": [{"binding": "HYPERDRIVE", "id": "<ID>"}]
}
```

```typescript
import { Client } from "pg";

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const client = new Client({ connectionString: env.HYPERDRIVE.connectionString });
    await client.connect();
    const result = await client.query("SELECT * FROM users WHERE id = $1", [123]);
    await client.end();
    return Response.json(result.rows);
  },
};
```

## Related Docs

- [hyperdrive-patterns.md](./hyperdrive-patterns.md) - read-heavy, mixed read/write, multi-tenant, and performance patterns
- [hyperdrive-gotchas.md](./hyperdrive-gotchas.md) - limits, troubleshooting, migration, and alternatives
- [Cloudflare Docs](https://developers.cloudflare.com/hyperdrive/)
- [Discord #hyperdrive](https://discord.cloudflare.com)
