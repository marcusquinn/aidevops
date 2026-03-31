# Hyperdrive

Accelerates database queries from Workers via connection pooling, edge setup, query caching. Eliminates ~7 TCP/TLS/auth round-trips per connection. Auto-caches non-mutating queries (default 60s TTL).

**Supported:** PostgreSQL 11+, MySQL 5.7+ and compatibles (CockroachDB, Timescale, PlanetScale, Neon, Supabase).

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

## When to Use

**Good fit:** Global access to single-region DBs, high read ratios, popular queries, connection-heavy loads.
**Poor fit:** Write-heavy, real-time data (<1s freshness), single-region apps close to DB. See [hyperdrive-gotchas.md](./hyperdrive-gotchas.md) for alternatives.

## See Also

- [hyperdrive-patterns.md](./hyperdrive-patterns.md) — use cases, ORMs, performance tips
- [hyperdrive-gotchas.md](./hyperdrive-gotchas.md) — limits, troubleshooting, migration
- [Docs](https://developers.cloudflare.com/hyperdrive/) | [Discord #hyperdrive](https://discord.cloudflare.com)
