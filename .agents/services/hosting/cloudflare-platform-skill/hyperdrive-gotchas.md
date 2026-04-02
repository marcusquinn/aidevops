# Gotchas

See [hyperdrive.md](./hyperdrive.md) and [hyperdrive-patterns.md](./hyperdrive-patterns.md).

## Common Errors

| `error.message` contains | Cause | HTTP status | Action |
|--------------------------|-------|-------------|--------|
| `Failed to acquire a connection` | Pool exhausted | 503 | Reduce transaction duration; upgrade plan |
| `connection_refused` | DB refusing | 503 | Check firewall/limits |
| `timeout` / `deadline exceeded` | Query >60s | 504 | Optimize query; add indexes |
| `password authentication failed` | Bad credentials | 500 | Check credentials |
| `SSL` / `TLS` | TLS misconfiguration | 500 | Check `sslmode` setting |

Catch pattern: `const msg = error.message || ""; if (msg.includes("...")) { ... }`

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

## When NOT to Use

❌ Write-heavy workloads (limited cache benefit)
❌ Real-time data requirements (<1s freshness)
❌ Single-region apps close to DB
❌ Very simple apps (overhead unjustified)
❌ DB with strict connection limits already exceeded

Alternatives: D1 (Cloudflare native SQL), Durable Objects (stateful Workers), KV (global key-value), R2 (object storage).

## Supported Databases

**PostgreSQL 11+** (CockroachDB, Timescale, Materialize, Neon, Supabase) — `pg` >= 8.16.3. `sslmode`: `require`, `verify-ca`, `verify-full`.

**MySQL 5.7+** (PlanetScale) — `mysql2` >= 3.13.0. `sslMode`: `REQUIRED`, `VERIFY_CA`, `VERIFY_IDENTITY`.

## Resources

- [Docs](https://developers.cloudflare.com/hyperdrive/)
- [Getting Started](https://developers.cloudflare.com/hyperdrive/get-started/)
- [Wrangler Reference](https://developers.cloudflare.com/hyperdrive/reference/wrangler-commands/)
- [Supported DBs](https://developers.cloudflare.com/hyperdrive/reference/supported-databases-and-features/)
- [Discord #hyperdrive](https://discord.cloudflare.com)
- [Limit Increase Form](https://forms.gle/ukpeZVLWLnKeixDu7)
