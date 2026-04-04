<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudflare R2 SQL

Serverless distributed query engine for Apache Iceberg tables in R2 Data Catalog. Zero egress fees, open beta (free beyond standard R2 storage costs).

## Core Concepts

**Apache Iceberg**: Open table format for large-scale analytics — ACID transactions, schema evolution (add/rename/drop columns without rewriting data), optimized metadata (avoids full table scans). Supported by Spark, Trino, Snowflake, DuckDB, ClickHouse, PyIceberg.

**R2 Data Catalog**: Managed Iceberg catalog built into R2 bucket; standard Iceberg REST interface. Single source of truth for table metadata via immutable snapshots.

**Architecture**: Query Planner does top-down metadata investigation with multi-layer pruning (partition/column/row-group), streaming pipeline with early termination, uses partition and column stats (min/max, null counts). Query Execution: coordinator distributes to workers across Cloudflare network running Apache DataFusion; Arrow IPC format; Parquet column pruning; ranged reads from R2. Aggregation: scatter-gather (sum, count, avg) or shuffling (ORDER BY/HAVING via hash partitioning).

## Setup

### 1. Enable R2 Data Catalog

```bash
npx wrangler r2 bucket catalog enable <bucket-name>
```

Note the Warehouse name and Catalog URI from output. (Dashboard: R2 Object Storage > bucket > Settings > R2 Data Catalog > Enable.)

### 2. Create API Token

Permissions required: R2 Admin Read & Write (includes R2 SQL Read). Dashboard: R2 Object Storage > Manage API tokens > Create API token > Admin Read & Write.

### 3. Configure Environment

```bash
export WRANGLER_R2_SQL_AUTH_TOKEN=<your-token>
```

## Code Patterns

### Wrangler CLI Query

```bash
npx wrangler r2 sql query "<warehouse-name>" "
  SELECT * FROM namespace.table_name WHERE condition LIMIT 10"
```

### PyIceberg

```python
from pyiceberg.catalog.rest import RestCatalog

catalog = RestCatalog(
    name="my_catalog",
    warehouse="<WAREHOUSE>",
    uri="<CATALOG_URI>",
    token="<TOKEN>",
)
catalog.create_namespace_if_not_exists("default")
```

### Create Table & Append Data

```python
import pyarrow as pa

df = pa.table({"id": [1, 2, 3], "name": ["Alice", "Bob", "Charlie"], "score": [80.0, 92.5, 88.0]})
table = catalog.create_table(("default", "people"), schema=df.schema)
table.append(df)

scanned = table.scan().to_arrow()
print(scanned.to_pandas())
```

## SQL Reference

### Query Structure

```sql
SELECT column_list | aggregation_function
FROM table_name
WHERE conditions
[GROUP BY column_list]
[HAVING conditions]
[ORDER BY partition_key [DESC | ASC]]
[LIMIT number]
```

### Schema Discovery

```sql
SHOW DATABASES;          -- List namespaces
SHOW TABLES IN ns;       -- List tables
DESCRIBE ns.table_name;  -- Describe table
```

### SELECT Patterns

```sql
SELECT * FROM ns.table
WHERE timestamp BETWEEN '2025-01-01T00:00:00Z' AND '2025-01-31T23:59:59Z'
  AND status = 200
LIMIT 100;

SELECT * FROM ns.table
WHERE (status = 404 OR status = 500) AND method = 'POST' AND user_agent IS NOT NULL
ORDER BY timestamp DESC;
```

### Aggregations

Supported: `COUNT(*)`, `SUM(col)`, `AVG(col)`, `MIN(col)`, `MAX(col)`

```sql
SELECT region, MIN(price), MAX(price), AVG(price)
FROM ns.products GROUP BY region ORDER BY AVG(price) DESC;

SELECT category, SUM(amount)
FROM ns.sales WHERE sale_date >= '2024-01-01'
GROUP BY category HAVING SUM(amount) > 10000 LIMIT 10;
```

### Data Types

`integer` (1, 42), `float` (1.5, 3.14), `string` ('hello'), `boolean` (true/false), `timestamp` (RFC3339: '2025-01-01T00:00:00Z'), `date` ('2025-01-01')

### Operators & Limits

Comparison: `=`, `!=`, `<`, `<=`, `>`, `>=`, `LIKE`, `BETWEEN`, `IS NULL`, `IS NOT NULL`
Logical: `AND` (higher precedence), `OR` (lower precedence)

**CRITICAL**: `ORDER BY` only supports partition key columns. LIMIT range: 1-10,000 (default 500).

## Pipelines Integration

Schema file (`schema.json`):

```json
{"fields": [
  {"name": "user_id", "type": "string", "required": true},
  {"name": "event_type", "type": "string", "required": true},
  {"name": "amount", "type": "float64", "required": false}
]}
```

```bash
npx wrangler pipelines setup
```

Key config: destination = Data Catalog Table, compression = zstd, roll file time = 10s (dev) / 300+ (prod).

### Send Data to Pipeline

```bash
curl -X POST https://{stream-id}.ingest.cloudflare.com \
  -H "Content-Type: application/json" \
  -d '[{"user_id": "user_123", "event_type": "purchase", "amount": 29.99}]'
```

## Performance & Best Practices

- **Partitioning**: choose key based on query patterns (day(timestamp), hour(timestamp), region). Required for ORDER BY.
- **Query**: use WHERE filters, specify LIMIT, filter on high-selectivity columns first. Combine filters with `AND` for better pruning.
- **File size**: 100-500MB Parquet files after compression; use 300+ second roll intervals in Pipelines. Use zstd compression.
- **Pruning** (automatic): partition-level > file-level (column stats) > row-group level.
- **Syntax**: quote string values; use RFC3339 for timestamps; no implicit type conversions.

## Iceberg Metadata Structure

```text
bucket/
  metadata/
    snap-{id}.avro          # Snapshot (points to manifest list)
    {uuid}-m0.avro          # Manifest file (lists data files + stats)
    version-hint.text       # Current metadata version
    v{n}.metadata.json      # Table metadata (schema, snapshots)
  data/
    00000-0-{uuid}.parquet  # Data files
```

Hierarchy: Table metadata JSON > Snapshot > Manifest list > Manifest files > Parquet row group stats.

## Limitations (Open Beta)

- `ORDER BY` only on partition key columns
- `COUNT(*)` only — `COUNT(column)` not supported
- No aliases in SELECT, no subqueries, joins, or CTEs
- No nested column access; LIMIT max 10,000

## Connecting Other Engines

R2 Data Catalog supports the standard Iceberg REST catalog API.

### Spark (Scala)

```scala
val spark = SparkSession.builder()
  .config("spark.sql.catalog.my_catalog", "org.apache.iceberg.spark.SparkCatalog")
  .config("spark.sql.catalog.my_catalog.catalog-impl", "org.apache.iceberg.rest.RESTCatalog")
  .config("spark.sql.catalog.my_catalog.uri", catalogUri)
  .config("spark.sql.catalog.my_catalog.token", token)
  .config("spark.sql.catalog.my_catalog.warehouse", warehouse)
  .getOrCreate()
```

Snowflake, DuckDB, Trino, ClickHouse: supported via Iceberg REST catalog protocol — refer to engine-specific docs.

## Pricing (Future)

Open beta — no charges beyond standard R2 costs. 30+ days notice before billing begins.

| Item | Rate |
|------|------|
| R2 storage | $0.015/GB-month |
| Class A operations | $4.50/million |
| Class B operations | $0.36/million |
| Catalog operations | $9.00/million |
| Compaction | $0.05/GB + $4.00/million objects |
| Egress | $0 (always free) |

## Troubleshooting

| Error | Fix |
|-------|-----|
| "ORDER BY column not in partition key" | Only partition key columns allowed; check with DESCRIBE; remove ORDER BY or adjust partitioning |
| "Token authentication failed" | Verify `WRANGLER_R2_SQL_AUTH_TOKEN`; ensure R2 Admin Read & Write permissions; check expiry |
| "Table not found" | `SHOW DATABASES` then `SHOW TABLES IN namespace`; ensure catalog enabled on bucket |
| "No data returned" | Check WHERE conditions and BETWEEN time range; try removing filters |
| Slow queries | Check partition pruning; reduce LIMIT; ensure filters on partition key; target 100-500MB Parquet files |
| Query timeout | Add more restrictive WHERE filters; reduce LIMIT; consider better partitioning |

## Resources

- Docs: https://developers.cloudflare.com/r2-sql/
- Data Catalog: https://developers.cloudflare.com/r2/data-catalog/
- Blog: https://blog.cloudflare.com/r2-sql-deep-dive/
- Discord: https://discord.cloudflare.com/
