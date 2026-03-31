# Gotchas

See [hyperdrive.md](./hyperdrive.md), [hyperdrive-patterns.md](./hyperdrive-patterns.md).

## Limits

| Category | Limit | Free | Paid |
|----------|-------|------|------|
| Config | Max configs | 10 | 25 |
| Config | Username/DB name | 63 bytes | 63 bytes |
| Connection | Timeout | 15s | 15s |
| Connection | Idle timeout | 10min | 10min |
| Connection | Max origin connections | ~20 | ~100 |
| Query | Max duration | 60s | 60s |
| Query | Max cached response | 50MB | 50MB |

Queries >60s are terminated. Responses >50MB are returned but not cached.

## Common Errors

```typescript
try {
  const result = await client.query("SELECT * FROM users");
} catch (error: any) {
  const msg = error.message || "";

  if (msg.includes("Failed to acquire a connection")) {
    console.error("Pool exhausted - long transactions?");
    return new Response("Service busy", {status: 503});
  }
  if (msg.includes("connection_refused")) {
    console.error("DB refusing - firewall/limits?");
    return new Response("DB unavailable", {status: 503});
  }
  if (msg.includes("timeout") || msg.includes("deadline exceeded")) {
    console.error("Query timeout - exceeded 60s");
    return new Response("Query timeout", {status: 504});
  }
  if (msg.includes("password authentication failed")) {
    console.error("Auth failed - check credentials");
    return new Response("Config error", {status: 500});
  }
  if (msg.includes("SSL") || msg.includes("TLS")) {
    console.error("TLS issue - check sslmode");
    return new Response("Connection security error", {status: 500});
  }

  console.error("Unknown DB error:", error);
  return new Response("Internal error", {status: 500});
}
```

## Troubleshooting

**Connection refused:** Check firewall allows Cloudflare IPs → verify DB listening on port → confirm service running → check credentials.

**Pool exhausted:** Reduce transaction duration → avoid long queries (>60s) → don't hold connections during external calls → upgrade to paid plan.

Monitor active connections:

```sql
SELECT usename, application_name, client_addr, state
FROM pg_stat_activity
WHERE application_name = 'Cloudflare Hyperdrive';
```

**SSL/TLS failed:** Add `sslmode=require` (Postgres) or `sslMode=REQUIRED` (MySQL) → upload CA cert if self-signed → verify DB has SSL enabled → check cert expiry.

**Queries not cached:** Verify non-mutating (SELECT) → check for volatile functions (NOW(), RANDOM()) → confirm caching not disabled → use `wrangler dev --remote` to test → check `prepare=true` for postgres.js.

**Query timeout (>60s):** Optimize with indexes → reduce dataset (LIMIT) → break into smaller queries → use async processing.

**Local DB connection:** Verify `localConnectionString` correct → check DB running → confirm env var name matches binding → test with psql/mysql client.

**Env var not working:** Format: `CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_<BINDING>` → binding matches wrangler.jsonc → variable exported in shell → restart wrangler dev.

## Migration Checklist

- [ ] Create config via Wrangler
- [ ] Add binding to wrangler.jsonc
- [ ] Enable `nodejs_compat` flag
- [ ] Set `compatibility_date` >= `2024-09-23`
- [ ] Update code to `env.HYPERDRIVE.connectionString` (Postgres) or properties (MySQL)
- [ ] Configure `localConnectionString`
- [ ] Set `prepare: true` (postgres.js) or `disableEval: true` (mysql2)
- [ ] Test locally with `wrangler dev`
- [ ] Deploy + monitor pool usage
- [ ] Validate cache with `wrangler dev --remote`
- [ ] Update firewall (Cloudflare IPs)
- [ ] Configure observability

## Supported Databases

**PostgreSQL 11+** (CockroachDB, Timescale, Materialize, Neon, Supabase) — `pg` >= 8.16.3. `sslmode`: `require`, `verify-ca`, `verify-full`.

**MySQL 5.7+** (PlanetScale) — `mysql2` >= 3.13.0. `sslMode`: `REQUIRED`, `VERIFY_CA`, `VERIFY_IDENTITY`.

## When NOT to Use

❌ Write-heavy workloads (limited cache benefit)
❌ Real-time data requirements (<1s freshness)
❌ Single-region apps close to DB
❌ Very simple apps (overhead unjustified)
❌ DB with strict connection limits already exceeded

Alternatives: D1 (Cloudflare native SQL), Durable Objects (stateful Workers), KV (global key-value), R2 (object storage).

## Resources

- [Docs](https://developers.cloudflare.com/hyperdrive/)
- [Getting Started](https://developers.cloudflare.com/hyperdrive/get-started/)
- [Wrangler Reference](https://developers.cloudflare.com/hyperdrive/reference/wrangler-commands/)
- [Supported DBs](https://developers.cloudflare.com/hyperdrive/reference/supported-databases-and-features/)
- [Discord #hyperdrive](https://discord.cloudflare.com)
- [Limit Increase Form](https://forms.gle/ukpeZVLWLnKeixDu7)
