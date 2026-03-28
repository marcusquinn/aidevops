# Cloudflare Pipelines Skill

Expert guidance for Cloudflare Pipelines - ETL streaming data platform for ingesting, transforming, and loading data into R2.

## Overview

Cloudflare Pipelines ingests events, transforms them with SQL, and delivers to R2 as Apache Iceberg tables or Parquet/JSON files.

**Core components:**
- **Streams**: Durable, buffered queues for event ingestion via HTTP or Workers. Structured (with schema validation) or unstructured (raw JSON). Can be read by multiple pipelines.
- **Pipelines**: Execute SQL transformations (filter, transform, enrich). Cannot be modified after creation — delete/recreate required.
- **Sinks**: Write to R2 Data Catalog (Apache Iceberg, ACID guarantees) or R2 Storage (Parquet/JSON). Exactly-once delivery.

**Status**: Open beta (Workers Paid plan required). No charge beyond standard R2 storage/operations.

**Use cases**: Analytics pipelines, data warehousing (ETL into Iceberg), event processing, log aggregation.

## Setup & Configuration

### Quick Start

```bash
# Interactive setup (recommended — creates stream, sink, pipeline)
npx wrangler pipelines setup

# Manual setup
npx wrangler r2 bucket create my-bucket
npx wrangler r2 bucket catalog enable my-bucket
npx wrangler pipelines streams create my-stream --schema-file schema.json
npx wrangler pipelines sinks create my-sink --type r2-data-catalog \
  --bucket my-bucket --namespace default --table my_table --catalog-token YOUR_TOKEN
npx wrangler pipelines create my-pipeline \
  --sql "INSERT INTO my_sink SELECT * FROM my_stream"
```

### Schema Definition

**Structured streams** (recommended for validation):

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

**Supported types**: `string`, `int32`, `int64`, `float32`, `float64`, `bool`, `timestamp`, `json`, `binary`, `list`, `struct`

**Unstructured streams** (no validation, single `value` column):
```bash
npx wrangler pipelines streams create my-stream
```

## Writing Data to Streams

### Via Workers (Recommended)

**wrangler.toml:**
```toml
[[pipelines]]
pipeline = "<STREAM_ID>"
binding = "STREAM"
```

**wrangler.jsonc:**
```jsonc
{ "pipelines": [{ "pipeline": "<STREAM_ID>", "binding": "STREAM" }] }
```

**Worker code:**
```typescript
export default {
  async fetch(request, env, ctx): Promise<Response> {
    // Single or batch events
    await env.STREAM.send([{ user_id: "12345", event_type: "purchase", amount: 29.99 }]);
    
    // Fire-and-forget (don't block response)
    ctx.waitUntil(env.STREAM.send([event]));
    
    return new Response('Event sent');
  },
} satisfies ExportedHandler<Env>;
```

### Via HTTP

```bash
# Without auth (testing)
curl -X POST https://{stream-id}.ingest.cloudflare.com \
  -H "Content-Type: application/json" \
  -d '[{"user_id": "user_12345", "event_type": "purchase", "amount": 29.99}]'

# With auth (production) — requires "Workers Pipeline Send" permission
curl -X POST https://{stream-id}.ingest.cloudflare.com \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_TOKEN" \
  -d '[{"event": "data"}]'
```

## SQL Transformations

```sql
-- Pass-through
INSERT INTO my_sink SELECT * FROM my_stream

-- Filter
INSERT INTO my_sink SELECT * FROM my_stream WHERE event_type = 'purchase' AND amount > 100

-- Transform with enrichment
INSERT INTO my_sink
SELECT
  user_id,
  UPPER(event_type) as event_type,
  amount * 1.1 as amount_with_tax,
  CASE WHEN amount > 1000 THEN 'high_value' WHEN amount > 100 THEN 'medium_value' ELSE 'low_value' END as tier
FROM my_stream
WHERE event_type IN ('purchase', 'refund')
```

**Constraints**: No JOINs across streams (single stream per pipeline). Cannot modify pipelines after creation.

## Sink Configuration

### R2 Data Catalog (Iceberg Tables)

```bash
npx wrangler pipelines sinks create my-sink \
  --type r2-data-catalog \
  --bucket my-bucket \
  --namespace my_namespace \
  --table my_table \
  --catalog-token YOUR_CATALOG_TOKEN \
  --compression zstd \
  --roll-interval 60 \
  --roll-size 100
```

**Options**: `--compression`: `zstd` (default), `snappy`, `gzip`, `lz4`, `uncompressed`. `--roll-interval`: seconds between writes (default: 300). `--roll-size`: max file size in MB.

**Query with R2 SQL:**
```bash
export WRANGLER_R2_SQL_AUTH_TOKEN=YOUR_API_TOKEN
npx wrangler r2 sql query "warehouse_name" "SELECT user_id, COUNT(*) FROM default.my_table GROUP BY user_id LIMIT 100"
```

### R2 Storage (Raw Files)

```bash
# Parquet (better compression/performance)
npx wrangler pipelines sinks create my-sink \
  --type r2 --bucket my-bucket --format parquet --compression zstd \
  --path analytics/events --partitioning "year=%Y/month=%m/day=%d/hour=%H" \
  --target-row-group-size 256 --roll-interval 300 --roll-size 100 \
  --access-key-id YOUR_KEY --secret-access-key YOUR_SECRET
```

Files organized as: `bucket/analytics/events/year=2025/month=01/day=11/uuid.parquet`

## Wrangler Commands Reference

```bash
# Pipelines
npx wrangler pipelines setup                          # Interactive setup
npx wrangler pipelines list
npx wrangler pipelines get <PIPELINE_ID>
npx wrangler pipelines delete <PIPELINE_ID>
npx wrangler pipelines create my-pipeline --sql "INSERT INTO sink SELECT * FROM stream"
npx wrangler pipelines create my-pipeline --sql-file transform.sql

# Streams
npx wrangler pipelines streams create my-stream --schema-file schema.json
npx wrangler pipelines streams list
npx wrangler pipelines streams get <STREAM_ID>
npx wrangler pipelines streams delete <STREAM_ID>    # WARNING: deletes dependent pipelines + buffered events

# Sinks
npx wrangler pipelines sinks create my-sink --type r2-data-catalog --bucket my-bucket --namespace default --table my_table --catalog-token TOKEN
npx wrangler pipelines sinks list
npx wrangler pipelines sinks get <SINK_ID>
npx wrangler pipelines sinks delete <SINK_ID>
```

## Authentication & Permissions

| Token type | Required permission | Used for |
|-----------|---------------------|---------|
| R2 Data Catalog | R2 Admin Read & Write | Sink creation, R2 SQL queries |
| R2 Storage | Object Read & Write | R2 storage sink |
| HTTP Ingest | Workers Pipeline Send | Authenticated HTTP ingestion |

Create R2 catalog token: R2 > Manage API tokens > Create Account API Token > Admin Read & Write.

## Best Practices

**Schema design:**
- Use structured streams for validation; mark critical fields `required: true`
- Use `int64` for timestamps, `float64` for decimals
- Don't change schemas after creation (recreate stream); avoid overly nested structs

**Performance:**
- Low latency: `--roll-interval 10` (smaller files, more frequent)
- Query performance: `--roll-interval 300 --roll-size 100` (larger files)
- Use `zstd` for best compression ratio, `snappy` for speed
- Filter early with `WHERE` clauses to reduce data volume

**Workers integration:**
- Use Worker bindings (no token management)
- Batch events: `send([event1, event2, ...])`
- Use `ctx.waitUntil()` for fire-and-forget (don't block response)

**HTTP ingestion:**
- Enable auth for production endpoints; configure CORS for browser clients
- Send arrays (not single objects) for batch efficiency
- Handle 4xx/5xx with retries

## Limits (Open Beta)

| Resource | Limit |
|----------|-------|
| Streams per account | 20 |
| Sinks per account | 20 |
| Pipelines per account | 20 |
| Payload size per request | 1 MB |
| Ingest rate per stream | 5 MB/s |

Request increases: [Limit Increase Form](https://forms.gle/ukpeZVLWLnKeixDu7)

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Events not in R2 | Wait 10-300s (depends on `--roll-interval`); check pipeline status; verify sink credentials |
| Schema validation failures | Events accepted but dropped if invalid; verify required fields and data types match schema |
| Worker binding not found | Verify `wrangler.toml`/`wrangler.jsonc` has correct `pipeline` ID; redeploy Worker |
| SQL errors | Cannot modify after creation — recreate pipeline; verify stream/sink names in SQL |

## Additional Resources

- [Pipelines Documentation](https://developers.cloudflare.com/pipelines/)
- [SQL Reference](https://developers.cloudflare.com/pipelines/sql-reference/)
- [R2 Data Catalog](https://developers.cloudflare.com/r2/data-catalog/)
- [Wrangler Commands](https://developers.cloudflare.com/workers/wrangler/commands/#pipelines)
- [Apache Iceberg](https://iceberg.apache.org/)
