# Cloudflare Vectorize Skill

Expert guidance for Cloudflare Vectorize - globally distributed vector database for AI applications.

## Overview

Vectorize stores and queries vector embeddings for semantic search, recommendations, classification, and anomaly detection. Seamlessly integrates with Workers AI.

**Key specs**: Up to 1536 dimensions (32-bit float), up to 5M vectors per index (V2), 3 distance metrics, metadata filtering (up to 10 indexes per index), namespace support.

**Status**: Generally Available (GA) — requires Wrangler 3.71.0+

## Index Configuration

### Creating Indexes

```bash
npx wrangler@latest vectorize create <index-name> \
  --dimensions=<number> \
  --metric=<euclidean|cosine|dot-product>
```

**CRITICAL: Index configuration is immutable after creation. Cannot change dimensions or metric.**

#### Distance Metrics

| Metric | Best For | Score Interpretation |
|--------|----------|---------------------|
| `euclidean` | Absolute distance, spatial data | Lower = closer (0.0 = identical) |
| `cosine` | Text embeddings, semantic similarity | Higher = closer (1.0 = identical) |
| `dot-product` | Recommendation systems, normalized vectors | Higher = closer |

- Text/semantic search → `cosine` (most common)
- Image similarity → `euclidean`
- Pre-normalized vectors → `dot-product`

#### Naming Conventions

Lowercase/numeric ASCII, start with letter, dashes only, < 32 characters. E.g., `production-doc-search`.

### Metadata Indexes

Enable filtering on metadata properties (up to 10 per index):

```bash
# Create BEFORE inserting vectors — existing vectors won't be indexed retroactively
npx wrangler vectorize create-metadata-index <index-name> \
  --property-name=<field-name> \
  --type=<string|number|boolean>
```

- String fields: first 64 bytes indexed (UTF-8 boundary); number fields: float64 precision
- **High cardinality** (UUIDs, ms timestamps): Good for `$eq`, poor for range queries — bucket to 5-min windows
- **Low cardinality** (enum values, status): Good for filters

```bash
npx wrangler vectorize list-metadata-index <index-name>
npx wrangler vectorize delete-metadata-index <index-name> --property-name=<field>
npx wrangler vectorize info <index-name>          # vector count, processed mutations
npx wrangler vectorize list-vectors <index-name> --count=100 --cursor=<cursor>
```

## Worker Binding

**wrangler.jsonc:**
```jsonc
{ "vectorize": [{ "binding": "VECTORIZE", "index_name": "production-index" }] }
```

**wrangler.toml:**
```toml
[[vectorize]]
binding = "VECTORIZE"
index_name = "production-index"
```

```typescript
export interface Env { VECTORIZE: Vectorize; }
// Run: npx wrangler types  (after config changes)
```

## Vector Operations

### Vector Format

```typescript
interface VectorizeVector {
  id: string;              // Unique identifier (max 64 bytes)
  values: number[] | Float32Array | Float64Array;  // Match index dimensions exactly
  namespace?: string;      // Optional partition key (max 64 bytes)
  metadata?: Record<string, string | number | boolean | null>;  // Max 10 KiB
}
```

Values stored as Float32 (Float64 converted on insert). Dense arrays only.

### Insert vs Upsert

```typescript
// INSERT: Ignore duplicates (first wins)
await env.VECTORIZE.insert([{ id: "1", values: [...], metadata: { url: "/products/sku/123" } }]);

// UPSERT: Overwrite existing (last wins, no merge)
await env.VECTORIZE.upsert([{ id: "1", values: [...], metadata: { url: "/products/sku/123", updated: true } }]);
```

Both return `{ mutationId: string }`. Asynchronous — takes a few seconds to be queryable.

**Batch limits**: Workers: 1000 vectors/batch; HTTP API: 5000/batch; File upload: 100 MB max.

### Querying

```typescript
const matches = await env.VECTORIZE.query(queryVector, {
  topK: 5,                    // Default: 5, Max: 100 (or 20 with values/metadata)
  returnValues: false,
  returnMetadata: "none",     // "none" | "indexed" | "all"
  namespace: "user-123",      // Optional
  filter: { category: "electronics" }  // Optional metadata filter
});
// Returns: { count: number, matches: Array<{ id, score, values?, metadata? }> }

// Query by existing vector ID
await env.VECTORIZE.queryById("some-vector-id", { topK: 5, returnValues: true });

// Retrieve specific vectors
await env.VECTORIZE.getByIds(["11", "22", "33"]);

// Delete by IDs (async)
await env.VECTORIZE.deleteByIds(["11", "22", "33"]);

// Get index config
await env.VECTORIZE.describe();  // { dimensions, metric, vectorCount? }
```

### Metadata Filtering

```typescript
// Implicit $eq
filter: { category: "electronics" }

// Explicit operators
filter: {
  category: { $ne: "deprecated" },
  price: { $gte: 10, $lt: 100 },
  tags: { $in: ["featured", "sale"] }
}

// Nested metadata with dot notation
filter: { "product.brand": "acme" }

// Prefix search via range
filter: { category: { $gte: "elec", $lt: "eled" } }  // Matches "electronics"
```

**Operators**: `$eq` (implicit), `$ne`, `$in`, `$nin`, `$lt`, `$lte`, `$gt`, `$gte`

**Filter constraints**: Max 2048 bytes (compact JSON). Keys: no empty, no dots, no `$` prefix, max 512 chars. Namespaces filtered before metadata.

## Namespaces

Partition vectors within a single index by customer, tenant, or category.

```typescript
await env.VECTORIZE.insert([
  { id: "1", values: [...], namespace: "customer-abc" }
]);
const matches = await env.VECTORIZE.query(queryVector, { namespace: "customer-abc" });
```

**Limits**: 50,000 namespaces (Paid) / 1,000 (Free). Max 64 bytes per namespace name.

## Integration Patterns

### Workers AI

```typescript
const embeddings = await ai.run("@cf/baai/bge-base-en-v1.5", { text: [userQuery] });
// Pass embeddings.data[0], NOT embeddings or embeddings.data
const matches = await env.VECTORIZE.query(embeddings.data[0], { topK: 3, returnMetadata: "all" });
```

**Common models**: `@cf/baai/bge-base-en-v1.5` (768d), `@cf/baai/bge-large-en-v1.5` (1024d), `@cf/baai/bge-small-en-v1.5` (384d)

### OpenAI

```typescript
const response = await openai.embeddings.create({ model: "text-embedding-ada-002", input: userQuery });
// Pass response.data[0].embedding, NOT response
const matches = await env.VECTORIZE.query(response.data[0].embedding, { topK: 5 });
```

### RAG Pattern

```typescript
// 1. Generate query embedding
const embeddings = await env.AI.run("@cf/baai/bge-base-en-v1.5", { text: [query] });
// 2. Search Vectorize
const matches = await env.VECTORIZE.query(embeddings.data[0], { topK: 5, returnMetadata: "all" });
// 3. Fetch full documents from R2/D1/KV
const documents = await Promise.all(matches.matches.map(m => env.R2_BUCKET.get(m.metadata?.r2_key).then(o => o?.text())));
// 4. Generate response with context
const llmResponse = await env.AI.run("@cf/meta/llama-3-8b-instruct", {
  prompt: `Context: ${documents.filter(Boolean).join("\n\n")}\n\nQuestion: ${query}\n\nAnswer:`
});
```

## CLI Operations

### Bulk Upload (NDJSON)

```bash
# File format: { "id": "1", "values": [0.1, 0.2, ...], "metadata": {"url": "/doc/1"}}
npx wrangler vectorize insert <index-name> --file=embeddings.ndjson
# Max 5000 vectors per file — use multiple files for larger batches
```

### Python HTTP API

```python
url = f"https://api.cloudflare.com/client/v4/accounts/{account_id}/vectorize/v2/indexes/{index_name}/insert"
with open('embeddings.ndjson', 'rb') as f:
    resp = requests.post(url, headers={"Authorization": f"Bearer {api_token}"}, files=dict(vectors=f))
```

## Performance Optimization

### Write Throughput

Vectorize batches up to 200K vectors OR 1000 operations per job. Batch size matters:

```typescript
// BAD: 250,000 individual inserts = 250 jobs = ~1 hour
for (const vector of vectors) { await env.VECTORIZE.insert([vector]); }

// GOOD: 100 batches of 2,500 = 2-3 jobs = minutes
for (let i = 0; i < vectors.length; i += 2500) {
  await env.VECTORIZE.insert(vectors.slice(i, i + 2500));
}
```

### Query Performance

- `returnValues: true` → high-precision scoring (slower, topK max 20)
- Default → approximate scoring (faster, topK max 100)
- Namespace filters applied first (fastest); high-cardinality range queries degrade performance
- Track mutations: `npx wrangler vectorize info <index-name>` (compare `processedUpToMutation` with insert `mutationId`)

## Limits (V2)

| Resource | Limit |
|----------|-------|
| Indexes per account | 50,000 (Paid) / 100 (Free) |
| Max dimensions | 1536 (32-bit float) |
| Max vector ID length | 64 bytes |
| Metadata per vector | 10 KiB |
| Max topK (no values/metadata) | 100 |
| Max topK (with values/metadata) | 20 |
| Insert batch size (Workers) | 1000 |
| Insert batch size (HTTP API) | 5000 |
| Max vectors per index | 5,000,000 |
| Max namespaces | 50,000 (Paid) / 1,000 (Free) |
| Max upload size | 100 MB |
| Max metadata indexes | 10 |
| Indexed metadata per field | 64 bytes (strings, UTF-8) |

## Multi-Tenant Architecture

```typescript
// Option 1: Separate indexes per tenant (if < 50K tenants)
const tenantIndex = env[`VECTORIZE_${tenantId.toUpperCase()}`];

// Option 2: Namespaces (up to 50K, fastest)
await env.VECTORIZE.insert([{ id: "doc-1", values: [...], namespace: `tenant-${tenantId}` }]);
const matches = await env.VECTORIZE.query(queryVector, { namespace: `tenant-${tenantId}` });

// Option 3: Metadata filtering (flexible but slower)
const matches = await env.VECTORIZE.query(queryVector, { filter: { tenantId } });
```

## Best Practices & Common Mistakes

**Do:**
1. Create metadata indexes BEFORE inserting vectors (existing vectors not retroactively indexed)
2. Use `upsert` for updates — `insert` ignores duplicates
3. Batch 1000-2500 vectors per operation for optimal throughput
4. Use `returnMetadata: "indexed"` for speed, `"all"` only when needed
5. Use namespace filtering instead of metadata when possible (faster)
6. Handle async operations — inserts/upserts take seconds to be queryable

**Don't:**
1. Pass wrong data shape: Workers AI → `embeddings.data[0]`; OpenAI → `response.data[0].embedding`
2. Return all values/metadata by default — impacts performance and topK limit
3. Use high-cardinality range queries — bucket or use discrete values
4. Forget `npx wrangler types` after config changes

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Vectors not appearing | Wait 5-10s; check `wrangler vectorize info <index>` for mutation processing |
| Dimension mismatch | Verify query vector length matches index dimensions exactly |
| Filter not working | Verify metadata index exists (`list-metadata-index`); re-upsert vectors after creating index |
| Performance issues | Reduce topK with returnValues/returnMetadata; simplify filters; batch operations |

## Resources

- [Official Docs](https://developers.cloudflare.com/vectorize/)
- [Client API Reference](https://developers.cloudflare.com/vectorize/reference/client-api/)
- [Metadata Filtering](https://developers.cloudflare.com/vectorize/reference/metadata-filtering/)
- [Limits](https://developers.cloudflare.com/vectorize/platform/limits/)
- [Workers AI Models](https://developers.cloudflare.com/workers-ai/models/#text-embeddings)
- [Wrangler Commands](https://developers.cloudflare.com/workers/wrangler/commands/#vectorize)
- [Discord: #vectorize](https://discord.cloudflare.com)

## Related

- **Vector search decision guide**: `tools/database/vector-search.md` — compare Vectorize with zvec, pgvector, and other vector databases
- **Multi-org isolation**: `services/database/multi-org-isolation.md` — tenant isolation schema patterns

---

**Version:** V2 (GA) - Requires Wrangler 3.71.0+
