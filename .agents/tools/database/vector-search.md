---
description: Vector search decision guide for multi-tenant SaaS — zvec, pgvector, Cloudflare Vectorize, PGlite+pgvector, hosted options
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Vector Search for Multi-Tenant SaaS

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Choose and implement vector search for per-tenant RAG pipelines in SaaS applications
- **Primary recommendation**: zvec (embedded, collection-per-tenant) or pgvector (if already on Postgres)
- **Scope**: Application-level vector search for user/org document retrieval — NOT for aidevops internal use (which stays on SQLite FTS5)

**Options covered**:

| Option | Type | Package/Service |
|--------|------|-----------------|
| zvec | Embedded (C++ in-process) | `zvec` (PyPI) / `@zvec/zvec` (npm, early) |
| pgvector | Postgres extension | `pgvector` extension + `drizzle-orm` |
| Cloudflare Vectorize | Managed (edge) | Cloudflare Workers binding |
| PGlite + pgvector | Embedded (WASM) | `@electric-sql/pglite` + pgvector extension |
| Pinecone | Hosted | `@pinecone-database/pinecone` |
| Qdrant | Self-hosted or cloud | `@qdrant/js-client-rest` |
| Weaviate | Self-hosted or cloud | `weaviate-client` |

<!-- AI-CONTEXT-END -->

## Decision Flowchart

```text
Do you need vector search for a SaaS app with per-tenant data?
  NO  --> This guide is not for you. For code search, use osgrep.
          For cross-session memory, use SQLite FTS5 (memory/).
  YES --> Is your app already on Postgres?
    YES --> Do you need >10M vectors per tenant?
      YES --> pgvector with partitioning, or Qdrant/Pinecone for scale
      NO  --> pgvector (simplest — one fewer dependency)
    NO  --> Do you want zero external dependencies?
      YES --> zvec (embedded, in-process, built-in embeddings)
      NO  --> Are you on Cloudflare Workers?
        YES --> Vectorize (native edge integration)
        NO  --> How many tenants?
          <100 tenants, predictable load --> Qdrant self-hosted
          >100 tenants, variable load   --> Pinecone or Weaviate Cloud
          Budget-constrained            --> zvec (no per-query cost)
```

## Comparison Matrix

### Core Capabilities

| Feature | zvec | pgvector | Vectorize | PGlite+pgvector | Pinecone | Qdrant | Weaviate |
|---------|------|----------|-----------|-----------------|----------|--------|----------|
| Deployment | In-process | Postgres ext. | Cloudflare edge | In-process (WASM) | Hosted | Self-host or cloud | Self-host or cloud |
| Max vectors (tested) | 10M+ | 100M+ | 5M/index | ~500K (WASM limit) | Billions | 100M+ | 100M+ |
| Dense search | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Sparse search | Yes (native) | No (use tsvector) | No | No | Sparse+dense | Sparse+dense | BM25 built-in |
| Hybrid search | Yes (multi-vector) | Manual (2 queries) | No | Manual | Yes | Yes | Yes |
| Built-in embeddings | Yes (local + API) | No | Workers AI | Via PGlite ext. | Inference API | FastEmbed | Built-in models |
| Built-in rerankers | RRF, weighted, cross-encoder | No | No | No | No | No | Reranker modules |
| Quantization | INT4, INT8, FP16 | Halfvec (FP16) | Automatic | Halfvec (FP16) | Automatic | Scalar, binary, product | PQ, BQ |
| Filtering | Structured fields | SQL WHERE | Metadata filter | SQL WHERE | Metadata filter | Payload filter | GraphQL filter |
| ACID transactions | No | Yes (Postgres) | No | Yes (PGlite) | No | No | No |
| License | Apache 2.0 | PostgreSQL | Proprietary | Apache 2.0 | Proprietary | Apache 2.0 | BSD-3-Clause |

### Operational Characteristics

| Factor | zvec | pgvector | Vectorize | PGlite+pgvector | Pinecone | Qdrant | Weaviate |
|--------|------|----------|-----------|-----------------|----------|--------|----------|
| Ops overhead | None (library) | Low (Postgres) | None (managed) | None (library) | None (managed) | Medium (server) | Medium (server) |
| Network latency | Zero (in-process) | LAN/localhost | Edge (<10ms) | Zero (in-process) | Internet (50-200ms) | LAN (1-5ms) | LAN (1-5ms) |
| Backup/restore | File copy | pg_dump | Automatic | File/IDB copy | Automatic | Snapshots | Backup API |
| Scaling model | Vertical only | Vertical (+ read replicas) | Automatic | Vertical only | Automatic | Sharding | Sharding |
| Multi-language | Python (full), Node.js (early) | Any (SQL) | JS/Workers only | JS/TS only | All major | All major | All major |
| Maturity | New (Dec 2025) | Mature (2021+) | GA (2024) | Stable (2024) | Mature (2019+) | Mature (2021+) | Mature (2019+) |

### Cost Model

| Option | Fixed cost | Per-query cost | Storage cost | Notes |
|--------|-----------|----------------|--------------|-------|
| zvec | $0 (OSS) | $0 (your compute) | Disk only | Cheapest at scale — no per-query fees |
| pgvector | $0 (OSS) | $0 (your compute) | Postgres storage | Shares existing Postgres cost |
| Vectorize | $0.01/1M queries | $0.04/1M stored vectors/mo | Included | Free tier: 30M queries/mo, 5M vectors |
| PGlite+pgvector | $0 (OSS) | $0 (client compute) | Client disk/IDB | Client-side only — no server cost |
| Pinecone | $0 (starter) | $0 (starter, 2M vectors) | $0.33/1M vectors/mo (standard) | Serverless: pay per read/write unit |
| Qdrant Cloud | $0 (1GB free) | Per-node pricing | Included in node | Self-hosted: $0 (your infra) |
| Weaviate Cloud | $0 (sandbox) | Per-node pricing | Included in node | Self-hosted: $0 (your infra) |

## Per-Tenant Isolation Patterns

Multi-tenant vector search requires isolating each organisation's data. The right pattern depends on your option and scale.

### Pattern 1: Collection-per-tenant (zvec)

Each tenant gets a separate zvec collection backed by its own filesystem directory. Physical isolation without running separate server instances.

```python
import zvec

# Create a collection for a new tenant
def create_tenant_collection(org_id: str, data_root: str = "/data/vectors"):
    path = f"{data_root}/{org_id}"
    schema = zvec.Schema()
    schema.add_field("id", zvec.DataType.STRING, primary_key=True)
    schema.add_field("content", zvec.DataType.STRING)
    schema.add_field("dense", zvec.DataType.VECTOR_FP32, dimension=384)
    schema.add_field("sparse", zvec.DataType.SPARSE_VECTOR_FP32)
    schema.add_field("source_file", zvec.DataType.STRING)
    schema.add_field("chunk_index", zvec.DataType.INT64)

    collection = zvec.create_and_open(path=path, schema=schema)
    collection.create_index("dense", zvec.IndexType.HNSW,
                            zvec.HnswIndexParam(quantize_type=zvec.QuantizeType.INT8))
    collection.create_index("sparse", zvec.IndexType.HNSW_SPARSE)
    return collection

# Open existing tenant collection
def open_tenant_collection(org_id: str, data_root: str = "/data/vectors"):
    return zvec.open(path=f"{data_root}/{org_id}")

# Delete tenant data (GDPR compliance)
def delete_tenant_data(org_id: str, data_root: str = "/data/vectors"):
    import shutil
    shutil.rmtree(f"{data_root}/{org_id}")
```

**Pros**: Physical isolation, simple GDPR deletion (rm -rf), no cross-tenant query leakage possible, independent scaling per tenant.

**Cons**: Application manages collection lifecycle, no built-in access control, memory grows with open collections (close idle tenants with LRU).

### Pattern 2: Schema-per-tenant with RLS (pgvector)

Use Postgres Row-Level Security for logical isolation within a shared table. Best when you already have a Postgres multi-tenant setup.

```sql
-- Shared embeddings table with tenant column
CREATE TABLE embeddings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES organisations(id),
    content TEXT NOT NULL,
    embedding vector(1536) NOT NULL,
    source_file TEXT,
    chunk_index INTEGER,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- HNSW index (shared across tenants)
CREATE INDEX ON embeddings USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 200);

-- Partition by org_id for large deployments
-- (optional — improves vacuum and tenant deletion)
CREATE TABLE embeddings_partitioned (
    LIKE embeddings INCLUDING ALL
) PARTITION BY HASH (org_id);

-- Row-Level Security
ALTER TABLE embeddings ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON embeddings
    USING (org_id = current_setting('app.current_org_id')::UUID);

-- Set tenant context per request (in your API middleware)
-- SET LOCAL app.current_org_id = '<org-uuid>';
```

```typescript
// Drizzle + pgvector example (server-side)
import { sql } from "drizzle-orm";
import { pgTable, uuid, text, integer, timestamp, index } from "drizzle-orm/pg-core";
import { vector } from "drizzle-orm/pg-core"; // Drizzle pgvector support

export const embeddings = pgTable("embeddings", {
  id: uuid("id").primaryKey().defaultRandom(),
  orgId: uuid("org_id").notNull(),
  content: text("content").notNull(),
  embedding: vector("embedding", { dimensions: 1536 }).notNull(),
  sourceFile: text("source_file"),
  chunkIndex: integer("chunk_index"),
  createdAt: timestamp("created_at").defaultNow(),
}, (table) => [
  index("embeddings_hnsw_idx").using("hnsw", table.embedding.op("vector_cosine_ops")),
]);

// Query with tenant context
async function searchTenant(db, orgId: string, queryEmbedding: number[], topK = 5) {
  await db.execute(sql`SET LOCAL app.current_org_id = ${orgId}`);
  return db.execute(sql`
    SELECT id, content, source_file, chunk_index,
           1 - (embedding <=> ${sql.raw(`'[${queryEmbedding.join(",")}]'::vector`)}) AS similarity
    FROM embeddings
    ORDER BY embedding <=> ${sql.raw(`'[${queryEmbedding.join(",")}]'::vector`)}
    LIMIT ${topK}
  `);
}
```

**Pros**: ACID transactions, leverages existing Postgres infra, SQL-based filtering, mature ecosystem.

**Cons**: RLS adds query overhead (~5-15%), shared index means all tenants compete for the same HNSW graph, vacuum on large shared tables is slow.

### Pattern 3: Namespace-per-tenant (Cloudflare Vectorize)

Vectorize uses namespaces for logical isolation within an index. Each namespace is a partition of the vector space.

```typescript
// Cloudflare Worker with Vectorize binding
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const orgId = getOrgIdFromAuth(request);

    // Insert vectors into tenant namespace
    await env.VECTORIZE_INDEX.upsert([{
      id: "doc-chunk-001",
      values: embeddingVector, // Float32Array
      namespace: orgId,       // Tenant isolation
      metadata: { source_file: "report.pdf", chunk_index: 0 },
    }]);

    // Query within tenant namespace only
    const results = await env.VECTORIZE_INDEX.query(queryVector, {
      topK: 5,
      namespace: orgId,
      returnMetadata: "all",
    });

    return Response.json(results.matches);
  },
};
```

**Pros**: Zero ops, edge latency, automatic scaling, namespace isolation is a first-class API.

**Cons**: Cloudflare-only, 5M vectors per index (request increase for more), no hybrid search, limited filtering.

### Pattern 4: Metadata filtering (Pinecone, Qdrant, Weaviate)

For hosted services, the simplest isolation is a `tenant_id` metadata field with mandatory filtering on every query.

```typescript
// Pinecone example
import { Pinecone } from "@pinecone-database/pinecone";

const pc = new Pinecone();
const index = pc.index("my-app");

// Upsert with tenant metadata
await index.namespace(orgId).upsert([{
  id: "doc-chunk-001",
  values: embeddingVector,
  metadata: { source_file: "report.pdf", chunk_index: 0 },
}]);

// Query scoped to tenant (Pinecone namespaces = physical isolation)
const results = await index.namespace(orgId).query({
  vector: queryVector,
  topK: 5,
  includeMetadata: true,
});
```

```typescript
// Qdrant example — uses payload filtering (logical isolation)
import { QdrantClient } from "@qdrant/js-client-rest";

const client = new QdrantClient({ url: "http://localhost:6333" });

await client.search("documents", {
  vector: queryVector,
  limit: 5,
  filter: {
    must: [{ key: "org_id", match: { value: orgId } }],
  },
  with_payload: true,
});
```

**Pinecone namespaces** provide physical isolation (separate storage partitions). **Qdrant/Weaviate payload filters** provide logical isolation (shared index, filtered at query time).

**Pros**: Simple to implement, works with any hosted provider.

**Cons**: Logical filtering depends on correct query construction (a missing filter leaks data), no physical isolation with payload filters, metadata filter overhead on large shared indexes.

## Per-Tenant RAG Pipeline

Regardless of which vector store you choose, the RAG pipeline follows the same stages:

```text
User uploads file (PDF/DOCX/TXT/HTML)
  │
  ▼
[Chunking] ─── Split by type (Docling for PDF, custom for text)
  │              Chunk size: 512-1024 tokens, 128-token overlap
  │
  ▼
[Embedding] ─── Choose based on vector store:
  │              zvec built-in: DefaultLocalDense (384d, free, local)
  │              OpenAI: text-embedding-3-small (1536d, API cost)
  │              Jina v5: jina-embeddings-v5-text-nano (1024d, Matryoshka to 256d)
  │
  ▼
[Store] ─── Insert into tenant-scoped collection/namespace/partition
  │          Schema: id, content_chunk, embedding, metadata
  │          Index: HNSW (default) or IVF (memory-constrained)
  │
  ▼
[Query] ─── User asks question
  │          1. Embed query (same model as storage)
  │          2. Search tenant's vectors (topK=20)
  │          3. Rerank (cross-encoder or RRF if hybrid)
  │          4. Return top-5 chunks with metadata
  │
  ▼
[LLM Context] ─── Assemble prompt: system + retrieved chunks + user query
                   Token budget: reserve for response, fill with chunks
```

**Embedding model consistency**: The query embedding model MUST match the storage embedding model. Mixing models (e.g., storing with OpenAI, querying with Jina) produces meaningless similarity scores.

## zvec Deep Dive

zvec is the newest option and least documented elsewhere, so it gets the deepest coverage here.

### What zvec is

An in-process C++ vector database built on Alibaba's Proxima engine. It runs inside your application process — no separate server, no network hop. Apache 2.0 licensed.

- **Repo**: https://github.com/alibaba/zvec
- **Stars**: ~8.4k (as of March 2026)
- **Created**: December 2025 — very new
- **Platforms**: Linux (x86_64, ARM64), macOS (ARM64). No Windows.
- **Bindings**: Python (full ecosystem), Node.js (core ops only, early stage)

### Key capabilities

**Index types**: HNSW, IVF (with SOAR optimisation), FLAT (brute-force), HNSW-Sparse, Flat-Sparse, Inverted (scalar filtering).

**Quantization**: INT4, INT8, FP16. INT8 is the recommended default — reduces memory ~4x with minimal recall loss.

**Built-in embedding functions** (Python only):

| Function | Model | Dimensions | Cost |
|----------|-------|------------|------|
| DefaultLocalDense | all-MiniLM-L6-v2 | 384 | Free (local) |
| DefaultLocalSparse (SPLADE) | splade-cocondenser-ensembledistil | Sparse | Free (local) |
| OpenAIDenseEmbedding | text-embedding-3-small/large | 1536/3072 | API cost |
| JinaDenseEmbedding | jina-embeddings-v5-text-nano | 1024 (Matryoshka to 32) | API cost |
| BM25EmbeddingFunction | DashText | Sparse | Free (local) |
| QwenDenseEmbedding | Qwen (DashScope) | Varies | API cost |

**Built-in rerankers** (Python only):

| Reranker | Type | Notes |
|----------|------|-------|
| RrfReRanker | Reciprocal Rank Fusion | For merging dense + sparse results |
| WeightedReRanker | Score-weighted merge | Configurable per-field weights |
| DefaultLocalReRanker | Cross-encoder | ms-marco-MiniLM-L6-v2 (local, free) |
| QwenReRanker | API-based | DashScope TextReRank service |

### Hybrid search example (Python)

```python
import zvec
from zvec.extension import (
    DefaultLocalDenseEmbedding,
    DefaultLocalSparseEmbedding,
    RrfReRanker,
)

# Embed query with both dense and sparse models
dense_fn = DefaultLocalDenseEmbedding()
sparse_fn = DefaultLocalSparseEmbedding()

query_text = "How does the billing system handle refunds?"
dense_vec = dense_fn.embed_query(query_text)
sparse_vec = sparse_fn.embed_query(query_text)

# Search tenant's collection with hybrid query
collection = zvec.open(path=f"/data/vectors/{org_id}")
results = collection.query(
    vector_queries=[
        zvec.VectorQuery(field="dense", vector=dense_vec, topk=20),
        zvec.VectorQuery(field="sparse", vector=sparse_vec, topk=20),
    ],
    reranker=RrfReRanker(rank_constant=60),
    topk=5,
    output_fields=["content", "source_file", "chunk_index"],
)

for doc in results:
    print(f"[{doc.score:.4f}] {doc.fields['source_file']}#{doc.fields['chunk_index']}")
    print(f"  {doc.fields['content'][:200]}...")
```

### Node.js status

The `@zvec/zvec` npm package (v0.2.1) provides core database operations via native C++ bindings. However, the Python extension ecosystem (embedding functions, rerankers, query executors) has **no Node.js equivalent**. For Node.js apps, you would:

1. Use zvec for storage/retrieval only
2. Bring your own embedding pipeline (OpenAI SDK, Transformers.js, etc.)
3. Implement reranking in application code

For production Node.js apps needing the full pipeline, pgvector or a hosted option may be more practical until the Node.js ecosystem matures.

### Performance characteristics

```text
Published benchmarks (Cohere 10M dataset, 16 vCPU / 64GB, INT8):

  zvec:
    Search latency:     Low milliseconds (1-5ms at 10M scale)
    Index build:        Competitive with HNSW implementations
    Memory (INT8):      ~25% of FP32 baseline

  Note: README claims "billions of vectors in milliseconds" but published
  benchmarks only test up to 10M. The billions claim likely refers to
  Alibaba's internal Proxima engine deployment, not publicly verified.
```

### zvec gotchas

1. **Very new** — Created December 2025. APIs may change. Community is small.
2. **Python-first** — Node.js bindings are early stage with no extension ecosystem.
3. **No Windows** — Linux and macOS only.
4. **Single-process** — No client-server mode. Only one process can open a collection at a time.
5. **No ACID** — Not a database in the transactional sense. Use application-level locking for concurrent writes.
6. **Memory per collection** — Each open collection consumes memory for its HNSW graph. Close idle tenant collections with an LRU cache.

## Platform Support Matrix

| Platform | zvec | pgvector | Vectorize | PGlite+pgvector | Pinecone | Qdrant | Weaviate |
|----------|------|----------|-----------|-----------------|----------|--------|----------|
| Node.js / Bun | Early (native addon) | Yes (pg driver) | No (Workers only) | Yes (WASM) | Yes | Yes | Yes |
| Python | Full | Yes (psycopg2) | No | No | Yes | Yes | Yes |
| Cloudflare Workers | No | No (no TCP) | Yes (native) | No (no FS) | Yes (HTTP) | Yes (HTTP) | Yes (HTTP) |
| Electron | Possible (native) | Via pg driver | No | Yes (WASM) | Yes (HTTP) | Yes (HTTP) | Yes (HTTP) |
| Browser extension | No | No | No | Yes (IndexedDB) | Yes (HTTP) | Yes (HTTP) | Yes (HTTP) |
| React Native | No | No | No | No (no WASM) | Yes (HTTP) | Yes (HTTP) | Yes (HTTP) |
| Docker / Linux server | Yes | Yes | No | Yes | Yes | Yes | Yes |
| macOS (ARM64) | Yes | Yes (Homebrew) | No | Yes | Yes | Yes | Yes |
| Windows | No | Yes | No | Yes | Yes | Yes | Yes |

## When to Use What — Summary

| Scenario | Recommendation | Why |
|----------|---------------|-----|
| Already on Postgres, <10M vectors/tenant | **pgvector** | Zero new dependencies, SQL filtering, ACID |
| No Postgres, want zero ops, Python app | **zvec** | In-process, built-in embeddings + rerankers, free |
| Cloudflare Workers app | **Vectorize** | Native edge integration, zero ops |
| Client-side search (Electron/extension) | **PGlite + pgvector** | WASM, works offline, shared Drizzle schema |
| Need to scale beyond 100M vectors | **Pinecone** or **Qdrant** | Purpose-built for scale, managed options |
| Regulated industry, strict data isolation | **Qdrant self-hosted** or **zvec** | Full control over data location |
| Prototyping / MVP | **Pinecone free tier** | Fastest to start, 2M vectors free |
| Node.js app, need full pipeline today | **pgvector** or **Pinecone** | zvec Node.js ecosystem is too early |

## Gotchas (All Options)

1. **Embedding model lock-in** — Changing embedding models requires re-embedding all stored vectors. Choose carefully upfront. Matryoshka models (Jina v5) offer dimension flexibility without re-embedding.
2. **Dimension mismatch** — Inserting 384d vectors into a 1536d index silently pads or fails depending on the store. Always validate dimensions match.
3. **Recall vs speed trade-off** — HNSW `ef_search` (query-time) and `ef_construction` (build-time) parameters directly trade recall for speed. Start with defaults, benchmark with your data.
4. **Stale embeddings** — When source documents update, their chunks and embeddings must be re-generated. Track `document_version` in metadata to detect staleness.
5. **Cost surprise with hosted** — Pinecone/Weaviate Cloud costs scale with stored vectors AND queries. A 10M vector index with high QPS can cost $100+/month. zvec/pgvector have zero per-query cost.
6. **PGlite+pgvector limits** — WASM overhead limits practical dataset size to ~500K vectors. For larger datasets, use server-side pgvector.
7. **Vectorize lock-in** — Only works in Cloudflare Workers. No local development story (use a mock or pgvector locally).

## Related

- **PGlite (local-first embedded Postgres)**: `tools/database/pglite-local-first.md`
- **Postgres + Drizzle**: `services/database/postgres-drizzle-skill.md`
- **SQLite FTS5 (aidevops memory)**: `memory/README.md` — for cross-session memory, NOT app vector search
- **Cloudflare Vectorize**: https://developers.cloudflare.com/vectorize/
- **zvec**: https://github.com/alibaba/zvec
- **pgvector**: https://github.com/pgvector/pgvector
- **Pinecone**: https://www.pinecone.io/
- **Qdrant**: https://qdrant.tech/
- **Weaviate**: https://weaviate.io/
