<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Hyperdrive

Connect Workers to PostgreSQL/MySQL with connection pooling and edge setup. Reuses origin connections to remove ~7 round-trips.

- **Compatibility**: CockroachDB, Timescale, PlanetScale, Neon, Supabase.
- **Best Fit**: Global users, single-region DB, read-heavy, or high connection setup cost.
- **Avoid**: Write-heavy, <1s freshness required, or Worker in same region as DB.

## Capabilities
- **Pooling**: Reuses origin connections.
- **Edge Setup**: Negotiates at edge, pools near DB.
- **Caching**: 60s default for non-mutating queries.

## Architecture
`Worker → Edge (setup) → Pool (near DB) → Origin`

## Quick Start
```bash
npx wrangler hyperdrive create my-db --connection-string="postgres://user:pass@host:5432/db"
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
- [Patterns](./hyperdrive-patterns.md) | [Gotchas](./hyperdrive-gotchas.md)
- [Cloudflare Docs](https://developers.cloudflare.com/hyperdrive/) | [Discord #hyperdrive](https://discord.cloudflare.com)
