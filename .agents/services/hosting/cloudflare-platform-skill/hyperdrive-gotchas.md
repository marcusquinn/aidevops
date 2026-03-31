# Hyperdrive Gotchas

See [Hyperdrive overview](./hyperdrive.md) and [Hyperdrive patterns](./hyperdrive-patterns.md).

## Hard limits

| Category | Limit | Free | Paid |
|----------|-------|------|------|
| Config | Max configs | 10 | 25 |
| Config | Username/DB name | 63 bytes | 63 bytes |
| Connection | Timeout | 15s | 15s |
| Connection | Idle timeout | 10min | 10min |
| Connection | Max origin connections | ~20 | ~100 |
| Query | Max duration | 60s | 60s |
| Query | Max cached response | 50MB | 50MB |

Queries over 60s are terminated. Responses over 50MB are returned but not cached.

## Common error handling

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

- **Connection refused** — allow Cloudflare IPs, verify DB port is listening, confirm the service is running, then re-check credentials.
- **Pool exhausted** — shorten transactions, avoid queries over 60s, do not hold connections during external calls, and upgrade if free-plan limits are the bottleneck.
- **SSL/TLS failed** — use `sslmode=require` (Postgres) or `sslMode=REQUIRED` (MySQL), upload a CA cert for self-signed deployments, confirm SSL is enabled, and check certificate expiry.
- **Queries not cached** — ensure the query is non-mutating, remove volatile functions (`NOW()`, `RANDOM()`), confirm caching is enabled, test with `wrangler dev --remote`, and set `prepare=true` for postgres.js.
- **Query timeout (>60s)** — add indexes, reduce result size with `LIMIT`, split the work into smaller queries, or move it to async processing.
- **Local DB connection** — verify `localConnectionString`, confirm the DB is running, match the env var name to the binding, and test with `psql` or `mysql`.
- **Env var not working** — use `CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_<BINDING>`, keep `<BINDING>` aligned with `wrangler.jsonc`, export the variable in the current shell, then restart `wrangler dev`.

Monitor active Hyperdrive sessions:

```sql
SELECT usename, application_name, client_addr, state
FROM pg_stat_activity
WHERE application_name = 'Cloudflare Hyperdrive';
```

## Migration checklist

- [ ] Create config via Wrangler
- [ ] Add binding to `wrangler.jsonc`
- [ ] Enable `nodejs_compat`
- [ ] Set `compatibility_date >= 2024-09-23`
- [ ] Update code to `env.HYPERDRIVE.connectionString` (Postgres) or connection properties (MySQL)
- [ ] Configure `localConnectionString`
- [ ] Set `prepare: true` (postgres.js) or `disableEval: true` (mysql2)
- [ ] Test locally with `wrangler dev`
- [ ] Deploy and monitor pool usage
- [ ] Validate cache behaviour with `wrangler dev --remote`
- [ ] Update firewall rules for Cloudflare IPs
- [ ] Configure observability

## Supported databases

- **PostgreSQL 11+** (CockroachDB, Timescale, Materialize, Neon, Supabase) — `pg >= 8.16.3`; `sslmode`: `require`, `verify-ca`, `verify-full`
- **MySQL 5.7+** (PlanetScale) — `mysql2 >= 3.13.0`; `sslMode`: `REQUIRED`, `VERIFY_CA`, `VERIFY_IDENTITY`

## Avoid Hyperdrive when

- Write-heavy workloads get little cache benefit.
- Real-time reads need freshness under 1 second.
- The app already runs close to a single-region database.
- The app is simple enough that Hyperdrive overhead is unjustified.
- The origin DB already exceeds strict connection limits.

Alternatives: D1 for Cloudflare-native SQL, Durable Objects for stateful Workers, KV for key-value reads, and R2 for object storage.

## Resources

- [Hyperdrive docs](https://developers.cloudflare.com/hyperdrive/)
- [Getting started](https://developers.cloudflare.com/hyperdrive/get-started/)
- [Wrangler reference](https://developers.cloudflare.com/hyperdrive/reference/wrangler-commands/)
- [Supported databases](https://developers.cloudflare.com/hyperdrive/reference/supported-databases-and-features/)
- [Discord #hyperdrive](https://discord.cloudflare.com)
- [Limit increase form](https://forms.gle/ukpeZVLWLnKeixDu7)
