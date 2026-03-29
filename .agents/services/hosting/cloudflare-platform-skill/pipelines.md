# Cloudflare Pipelines Skill

ETL streaming platform: ingest events, transform with SQL, deliver to R2 as Apache Iceberg tables or Parquet/JSON.

**Components:** Streams (durable buffered queues, structured or unstructured) → Pipelines (SQL transforms, immutable — delete/recreate to modify) → Sinks (R2 Data Catalog with Iceberg/ACID, or R2 Storage as Parquet/JSON; exactly-once delivery).

**Status:** Open beta, Workers Paid plan required, no charge beyond R2 storage/operations.

## Setup

```bash
npx wrangler pipelines setup                          # Interactive (recommended)
# Manual:
npx wrangler r2 bucket create my-bucket
npx wrangler r2 bucket catalog enable my-bucket
npx wrangler pipelines streams create my-stream --schema-file schema.json
npx wrangler pipelines sinks create my-sink --type r2-data-catalog \
  --bucket my-bucket --namespace default --table my_table --catalog-token YOUR_TOKEN
npx wrangler pipelines create my-pipeline \
  --sql "INSERT INTO my_sink SELECT * FROM my_stream"
```

**Schema (structured streams):**

```json
{
  "fields": [
    { "name": "user_id", "type": "string", "required": true },
    { "name": "event_type", "type": "string", "required": true },
    { "name": "amount", "type": "float64", "required": false },
    { "name": "tags", "type": "list", "required": false, "items": { "type": "string" } },
    { "name": "metadata", "type": "struct", "required": false,
      "fields": [{ "name": "source", "type": "string", "required": false }] }
  ]
}
```

**Types:** `string`, `int32`, `int64`, `float32`, `float64`, `bool`, `timestamp`, `json`, `binary`, `list`, `struct`. Unstructured streams (no validation, single `value` column): omit `--schema-file`.

## Writing Data

**Worker Binding (recommended):** Config — `wrangler.toml`: `[[pipelines]]` with `pipeline = "<STREAM_ID>"`, `binding = "STREAM"`. Or `wrangler.jsonc`: `{ "pipelines": [{ "pipeline": "<STREAM_ID>", "binding": "STREAM" }] }`.

```typescript
export default {
  async fetch(request, env, ctx): Promise<Response> {
    await env.STREAM.send([{ user_id: "12345", event_type: "purchase", amount: 29.99 }]);
    ctx.waitUntil(env.STREAM.send([event]));  // fire-and-forget
    return new Response('Event sent');
  },
} satisfies ExportedHandler<Env>;
```

**HTTP Ingestion:**

```bash
curl -X POST https://{stream-id}.ingest.cloudflare.com \
  -H "Content-Type: application/json" \
  -d '[{"user_id": "user_12345", "event_type": "purchase", "amount": 29.99}]'
# Production: add -H "Authorization: Bearer YOUR_API_TOKEN" (requires "Workers Pipeline Send" permission)
```

## SQL Transformations

```sql
INSERT INTO my_sink SELECT * FROM my_stream                                    -- pass-through
INSERT INTO my_sink SELECT * FROM my_stream WHERE event_type = 'purchase' AND amount > 100  -- filter
INSERT INTO my_sink SELECT user_id, UPPER(event_type) as event_type,           -- transform
  amount * 1.1 as amount_with_tax,
  CASE WHEN amount > 1000 THEN 'high_value' WHEN amount > 100 THEN 'medium_value' ELSE 'low_value' END as tier
FROM my_stream WHERE event_type IN ('purchase', 'refund')
```

**Constraints:** No JOINs across streams (single stream per pipeline). Pipelines immutable after creation.

## Sinks

**R2 Data Catalog (Iceberg):**

```bash
npx wrangler pipelines sinks create my-sink \
  --type r2-data-catalog --bucket my-bucket --namespace my_namespace \
  --table my_table --catalog-token YOUR_CATALOG_TOKEN \
  --compression zstd --roll-interval 60 --roll-size 100
```

**Compression:** `zstd` (default), `snappy`, `gzip`, `lz4`, `uncompressed`. **Roll:** `--roll-interval` seconds between writes (default 300), `--roll-size` max MB.

Query: `npx wrangler r2 sql query "warehouse_name" "SELECT user_id, COUNT(*) FROM default.my_table GROUP BY user_id LIMIT 100"` (set `WRANGLER_R2_SQL_AUTH_TOKEN`).

**R2 Storage (Raw Parquet/JSON):**

```bash
npx wrangler pipelines sinks create my-sink \
  --type r2 --bucket my-bucket --format parquet --compression zstd \
  --path analytics/events --partitioning "year=%Y/month=%m/day=%d/hour=%H" \
  --target-row-group-size 256 --roll-interval 300 --roll-size 100 \
  --access-key-id YOUR_KEY --secret-access-key YOUR_SECRET
```

Files: `bucket/analytics/events/year=2025/month=01/day=11/uuid.parquet`

## Wrangler Commands

```bash
npx wrangler pipelines setup | list | get <ID> | delete <ID>
npx wrangler pipelines create my-pipeline --sql "..." | --sql-file transform.sql
npx wrangler pipelines streams create my-stream --schema-file schema.json
npx wrangler pipelines streams list | get <ID> | delete <ID>  # WARNING: deletes dependent pipelines + buffered events
npx wrangler pipelines sinks create my-sink --type r2-data-catalog --bucket B --namespace N --table T --catalog-token TOKEN
npx wrangler pipelines sinks list | get <ID> | delete <ID>
```

## Auth & Permissions

| Token type | Permission | Used for |
|-----------|-----------|---------|
| R2 Data Catalog | R2 Admin Read & Write | Sink creation, R2 SQL queries |
| R2 Storage | Object Read & Write | R2 storage sink |
| HTTP Ingest | Workers Pipeline Send | Authenticated HTTP ingestion |

Create catalog token: R2 > Manage API tokens > Create Account API Token > Admin Read & Write.

## Best Practices

- **Schema:** Structured streams with `required: true` on critical fields. `int64` for timestamps, `float64` for decimals. Don't change schemas (recreate). Avoid deep nesting.
- **Performance:** Low latency: `--roll-interval 10`. Query perf: `--roll-interval 300 --roll-size 100`. `zstd` for ratio, `snappy` for speed. Filter early with `WHERE`.
- **Workers:** Bindings (no token management). Batch: `send([e1, e2, ...])`. `ctx.waitUntil()` for fire-and-forget.
- **HTTP:** Auth in production. CORS for browsers. Arrays for batch efficiency. Retry on 4xx/5xx.

## Limits (Open Beta)

| Resource | Limit |
|----------|-------|
| Streams / Sinks / Pipelines per account | 20 each |
| Payload size per request | 1 MB |
| Ingest rate per stream | 5 MB/s |

Request increases: [Limit Increase Form](https://forms.gle/ukpeZVLWLnKeixDu7)

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Events not in R2 | Wait 10-300s (depends on `--roll-interval`); check pipeline status; verify sink credentials |
| Schema validation failures | Events accepted but dropped if invalid; verify required fields and types match schema |
| Worker binding not found | Verify config has correct `pipeline` ID; redeploy Worker |
| SQL errors | Recreate pipeline (immutable); verify stream/sink names in SQL |

**Resources:** [Pipelines Docs](https://developers.cloudflare.com/pipelines/) · [SQL Reference](https://developers.cloudflare.com/pipelines/sql-reference/) · [R2 Data Catalog](https://developers.cloudflare.com/r2/data-catalog/) · [Wrangler Commands](https://developers.cloudflare.com/workers/wrangler/commands/#pipelines) · [Apache Iceberg](https://iceberg.apache.org/)
